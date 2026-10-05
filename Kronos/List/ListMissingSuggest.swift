// Kronos/List/ListMissingSuggest.swift
// The state behind "Suggest" in a list's missing group. It asks the existing triage pipeline (the
// neighbour vote, then the model when the person allows it) for ONE field of the tasks that lack it,
// shows what it found, and writes only what the person accepts, in a single undo step.
// Nothing here writes before the person taps Fill.
import SwiftUI
import KronosCore

@MainActor
@Observable
final class ListMissingSuggest {
    static let shared = ListMissingSuggest()

    enum Phase: Equatable { case idle, asking, ready, none }

    private(set) var phase: Phase = .idle
    private(set) var suggestions: [MissingSuggestion] = []
    /// What the current answer is about (list + sort key). A different list or key shows as idle.
    private(set) var subject = ""
    private var running: Task<Void, Never>?

    private init() {}

    static func subjectKey(scope: ListScope, key: KSortKey) -> String { scope.storageKey + "|" + key.rawValue }

    /// The current phase for `subject`: anything asked about another list or key does not count.
    func phase(for subject: String) -> Phase { self.subject == subject ? phase : .idle }

    /// Hidden entirely when the person's AI policy disallows asking: the Settings switch off, no
    /// router, or the privacy mode Off. The suggestion never leaves the Mac in those cases.
    static func mayAsk(_ model: AppModel) -> Bool {
        AICallPolicy.mayAsk(switchOn: TriagePrefs.aiSuggestionsEnabled, hasRouter: model.ai != nil,
                            mode: (model.ai as? AIRouter)?.mode)
    }

    /// At most `MissingSuggest.batchLimit` of `ids` are asked about.
    func ask(model: AppModel, ids: [UUID], key: KSortKey, scope: ListScope) {
        guard let kind = SortGrouping.fillKind(for: key), Self.mayAsk(model) else { return }
        running?.cancel()
        let tag = Self.subjectKey(scope: scope, key: key)
        subject = tag
        suggestions = []
        phase = .asking

        let store = model.store
        let subjects = ids.compactMap { store.task($0) }.map {
            MissingSuggest.Subject(id: $0.id, title: $0.title, notes: $0.notes, locked: $0.lockedFields)
        }
        let now = Date()
        let examples = store.allTasks().filter { $0.deletedAt == nil }.map { t in
            let age = now.timeIntervalSince(t.updatedAt) / 86_400
            return (id: t.id, source: TriageExampleSource(title: t.title, projectName: t.project?.name, priority: t.priority,
                                                          effort: t.effort, depth: t.depth, dueDay: t.dueDay,
                                                          open: t.status != .done, recency: 1 / (1 + max(0, age))))
        }
        let projectNames = store.allProjects(includeArchived: false).map(\.name)
        let labelNames = store.labels().map(\.name)
        let router = model.ai
        let modelID = (router as? AIRouter)?.candidates.first?.client.modelID
        let today = Day.today()

        running = Task { @MainActor [weak self] in
            let found = await MissingSuggest.suggest(for: subjects, kind: kind, examples: examples,
                                                     projectNames: projectNames, labelNames: labelNames,
                                                     today: today, router: router, modelID: modelID)
            guard let self, !Task.isCancelled, self.subject == tag else { return }
            self.suggestions = found
            self.phase = found.isEmpty ? .none : .ready
        }
    }

    /// Writes the suggestions for `ids` (all of them when nil) in one undo step and says so in the pill.
    func fill(_ ids: Set<UUID>? = nil, model: AppModel) {
        let chosen = suggestions.filter { ids?.contains($0.taskID) ?? true }
        guard !chosen.isEmpty else { return }
        let depth = model.store.undoDepth
        let filled = MissingSuggest.apply(chosen, to: model.store)
        let gone = Set(chosen.map(\.taskID))
        suggestions.removeAll { gone.contains($0.taskID) }
        if suggestions.isEmpty { phase = .idle }
        guard !filled.isEmpty, model.store.undoDepth != depth else {
            model.didMutate()   // refresh-only: nothing was empty any more, nothing to announce
            return
        }
        model.commit(String(format: String(localized: "list.missing.filled"), filled.count))
    }

    func dismiss() {
        running?.cancel()
        suggestions = []
        phase = .idle
    }

    /// The proposed value as the list shows it.
    static func text(_ value: MissingSuggestion.Value) -> String {
        switch value {
        case .due(let day): return ViewOptionsMapper.mediumDate(day)
        case .effort(let e): return ViewOptionsMapper.effortName(e)
        case .estimateMinutes(let n): return String(format: String(localized: "list.missing.minutes"), n)
        case .project(let name): return name
        }
    }
}
