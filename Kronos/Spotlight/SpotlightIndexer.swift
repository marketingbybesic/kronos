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
    /// Content hash of every entry the index holds, by id (SpotlightDiff).
    private var lastIndexed: [String: UInt64] = [:]
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
        return KronosEnv.isHermetic ? FixtureSearchIndex() : RealSearchIndex()
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
        let plan = SpotlightDiff.plan(previous: lastIndexed, current: facts.compactMap(SpotlightSafety.sanitize))
        // Remember a pass only when the index took it, so a failed write is retried next time.
        do {
            if !plan.delete.isEmpty { try await index.deleteItems(withIdentifiers: plan.delete) }
            if !plan.index.isEmpty { try await index.indexItems(plan.index) }
            lastIndexed = plan.hashes
        } catch {
            lastIndexed = lastIndexed.filter { plan.hashes[$0.key] == $0.value && !plan.delete.contains($0.key) }
        }
    }

    /// One pass now, without the debounce (tests and the first pass).
    func refreshNow() async { await refresh() }

    /// Every open task + every non-archived project, as plain facts. `static` + injectable
    /// `store`/`today` so `refresh()`'s only MainActor-only dependency is `model` itself.
    static func buildFacts(store: any TaskStoring, today: Int) -> [SearchableFacts] {
        // Subtasks are indexed too (subtitle = their parent's title): a Spotlight result for one
        // opens the parent's row with the inspector on the subtask (AppModel.openTaskByID).
        let parents = store.allTasks().filter { KStatus.open.contains($0.status) }
        let taskFacts = parents.flatMap { t -> [SearchableFacts] in
            let move = t.firstMove?.isEmpty == false ? t.firstMove : nil
            let words = ["Kronos"] + [t.project?.name].compactMap { $0 } + (t.labels ?? []).map(\.name)
            let own = SearchableFacts(id: "task.\(t.id.uuidString)", kind: .task, title: t.title,
                                      subtitle: t.project?.name, firstMove: move,
                                      deadlineText: t.effectiveDue.map(Day.iso),
                                      keywords: words, contentURL: TaskLink.string(for: t.id))
            let steps = t.orderedChildren.filter { KStatus.open.contains($0.status) }.map { c in
                SearchableFacts(id: "task.\(c.id.uuidString)", kind: .task, title: c.title,
                                subtitle: t.title, firstMove: nil, deadlineText: c.dueDay.map(Day.iso),
                                keywords: ["Kronos", t.title], contentURL: TaskLink.string(for: c.id))
            }
            return [own] + steps
        }
        let projectFacts = store.allProjects(includeArchived: false).map { p in
            SearchableFacts(id: "project.\(p.id.uuidString)", kind: .project, title: p.name,
                            subtitle: p.area?.name, keywords: ["Kronos"] + [p.area?.name].compactMap { $0 })
        }
        return taskFacts + projectFacts
    }

    /// Continuation hook: `AppDelegate.application(_:continue:restorationHandler:)` resolves a
    /// Spotlight click back to the task or project it was made from.
    static func target(from activity: NSUserActivity) -> SpotlightIdentifier.Target? {
        guard activity.activityType == CSSearchableItemActionType,
              let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return SpotlightIdentifier.parse(raw)
    }

    static func taskID(from activity: NSUserActivity) -> UUID? {
        if case .task(let id)? = target(from: activity) { return id }
        return nil
    }
}
