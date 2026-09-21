// Kronos/Spotlight/SpotlightIndexer.swift
//
// Keeps Spotlight's index of open tasks + non-archived projects in sync with the store.
// Incremental: after every `model.version` bump it diffs the current open/live id set
// against what it last indexed and only touches what changed, debounced so a burst of
// mutations (bulk triage, an MCP batch) coalesces into one pass. Hermetic under
// `KRONOS_SNAPSHOT`: `SpotlightIndexer.start(model:)` constructs a `FixtureSearchIndex`
// instead of the real one and never calls into CoreSpotlight.

import Foundation
import CoreSpotlight
import Observation
import KronosCore

@MainActor
final class SpotlightIndexer {
    private let model: AppModel
    private let index: any SearchIndexing
    private var lastIndexedIDs: Set<String> = []
    private var pending: Task<Void, Never>?
    /// Debounce window: several mutations in quick succession (bulk triage, a completion
    /// plus its recurrence spawn) collapse into one indexing pass instead of one per write.
    private let debounce: Duration

    /// `AppDelegate.applicationDidFinishLaunching` calls `SpotlightIndexer.start(model:)`
    /// alongside `KronosIntents.bootstrap` and keeps the result in a stored property
    /// (`private var spotlightIndexer: SpotlightIndexer?`) to keep it alive — this type owns
    /// no static/shared instance.
    @discardableResult
    static func start(model: AppModel, debounce: Duration = .milliseconds(400)) -> SpotlightIndexer {
        let indexer = SpotlightIndexer(model: model, index: Self.makeIndex(), debounce: debounce)
        indexer.observeVersion()
        indexer.scheduleRefresh()
        return indexer
    }

    /// `KRONOS_SNAPSHOT` (the same variable every other hermetic seam in the app checks,
    /// e.g. `AppModel.isHermetic`) forces the fixture index even outside of a unit test, so
    /// a snapshot run of any screen can never write to the real Spotlight index.
    private static func makeIndex() -> any SearchIndexing {
        // A scratch store (KRONOS_STORE_DIR) must never reach the real Spotlight index either.
        let env = ProcessInfo.processInfo.environment
        return (env["KRONOS_SNAPSHOT"] != nil || env["KRONOS_STORE_DIR"] != nil) ? FixtureSearchIndex() : RealSearchIndex()
    }

    init(model: AppModel, index: any SearchIndexing, debounce: Duration = .milliseconds(400)) {
        self.model = model
        self.index = index
        self.debounce = debounce
    }

    /// Re-arms itself after every fire: `withObservationTracking`'s `onChange` closure runs
    /// once, so this re-registers before doing anything else. `AppModel.version` bumps on
    /// EVERY store mutation (`didMutate()`'s doc comment) and `.kronosStoreDidChangeExternally`
    /// (MCP writes) already routes through `model.didMutate()` too, so watching `version`
    /// alone catches every source without a second notification observer.
    private func observeVersion() {
        withObservationTracking {
            _ = model.version
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeVersion()
                self.scheduleRefresh()
            }
        }
    }

    func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    private func refresh() async {
        let today = Day.today(calendar: KronosLocale.calendar)
        let facts = Self.buildFacts(store: model.store, today: today)
        let sanitized = facts.compactMap(SpotlightSafety.sanitize)
        let currentIDs = Set(sanitized.map(\.id))

        let removedIDs = lastIndexedIDs.subtracting(currentIDs)
        if !removedIDs.isEmpty { try? await index.deleteItems(withIdentifiers: Array(removedIDs)) }
        if !sanitized.isEmpty { try? await index.indexItems(sanitized) }
        lastIndexedIDs = currentIDs
    }

    /// Every open task + every non-archived project, as plain facts. `static` + injectable
    /// `store`/`today` so `refresh()`'s only MainActor-only dependency is `model` itself.
    static func buildFacts(store: any TaskStoring, today: Int) -> [SearchableFacts] {
        let taskFacts = store.allTasks()
            .filter { KStatus.open.contains($0.status) }
            .map { t -> SearchableFacts in
                let move = t.firstMove?.isEmpty == false ? t.firstMove : nil
                let deadline = t.dueDay.map(Day.iso)
                return SearchableFacts(id: "task.\(t.id.uuidString)", kind: .task, title: t.title,
                                       subtitle: t.project?.name, firstMove: move, deadlineText: deadline)
            }
        let projectFacts = store.allProjects(includeArchived: false).map { p in
            SearchableFacts(id: "project.\(p.id.uuidString)", kind: .project, title: p.name,
                            subtitle: p.area?.name)
        }
        return taskFacts + projectFacts
    }

    /// Continuation hook: `AppDelegate.application(_:continue:restorationHandler:)` calls
    /// `SpotlightIndexer.taskID(from:)` to resolve a Spotlight click back to a task, then
    /// selects it.
    ///
    /// (`.inbox` is a safe default scope so the task is reachable in the list regardless of
    /// which saved view/project scope was open when Spotlight was used; a leaf that owns
    /// `Kronos/App/**` may prefer resolving the task's own project scope instead.)
    static func taskID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              raw.hasPrefix("task.")
        else { return nil }
        return UUID(uuidString: String(raw.dropFirst("task.".count)))
    }
}
