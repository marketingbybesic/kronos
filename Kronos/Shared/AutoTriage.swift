// Auto-triage: when a task is created, look at the rest of the list and fill in what is EMPTY
// (priority, effort, project, depth, first move; a deadline only from words in the task itself).
// Never overwrites what the user typed; one undo step; works with AI off (neighbour vote).
// Screens never run triage on creation themselves — this is the one shared seam for it.
import Foundation
import KronosCore

@MainActor
final class AutoTriage {
    private let model: AppModel
    private var observer: NSObjectProtocol?

    /// Settings > Coach switches this off (CoachSettings.autoTriage). Default on.
    var isEnabled: Bool { model.coach.settings.autoTriage }

    init(model: AppModel) { self.model = model }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .kronosTaskDidCreate, object: nil,
                                                          queue: .main) { [weak self] note in
            guard let id = note.userInfo?["taskID"] as? UUID else { return }
            MainActor.assumeIsolated { self?.triage(id) }
        }
    }

    /// Also the entry point for "Re-triage" (fill-only by default).
    func triage(_ id: UUID, fillOnly: Bool = true) {
        guard isEnabled || !fillOnly, let task = model.store.task(id) else { return }
        let title = task.title, notes = task.notes
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let today = Day.today()
        let context = TriageContextBuilder.build(for: title, notes: notes, from: examples(excluding: id))
        let projectNames = model.store.allProjects(includeArchived: false).map(\.name)
        let router = model.ai

        Task { @MainActor [weak self] in
            guard let self else { return }
            var result = NeighbourTriage.infer(title: title, notes: notes, context: context, today: today)
            var isNeighbourSourced = true
            if let router,
               let ai = try? await router.triage(title: title, notes: notes, projectNames: projectNames,
                                                 labelNames: [], today: today, lockedFields: [],
                                                 context: context) {
                result = ai
                isNeighbourSourced = false
            }
            // The task may have been edited or deleted while the model was thinking: fill-only
            // keeps anything typed in the meantime, and a missing task is simply skipped.
            guard self.model.store.task(id) != nil else { return }
            let filled = self.model.store.applyTriage(result, to: id, fillOnly: fillOnly,
                                                      only: Self.allowedFields(self.model.coach.settings.triageMayFill))
            guard !filled.isEmpty else { return }
            self.lastFill[id] = Fill(fields: filled, reason: result.reason, isNeighbourSourced: isNeighbourSourced)
            self.model.didMutate()
        }
    }

    /// What the last triage filled, so the inspector can say "Filled: priority, effort - like 3
    /// similar Acme tasks" with a one-step Undo. `isNeighbourSourced` tells the inspector
    /// whether `reason` is one of NeighbourTriage's two fixed English shapes (needs
    /// localizedNeighbourReason at the render site) or arbitrary AI text already in the task's
    /// own language (spec §1's independent axis) — same distinction TriageFlowView's
    /// `suggestionSource` makes for the triage card.
    struct Fill { let fields: [TriageFieldKind]; let reason: String?; let isNeighbourSourced: Bool }
    private(set) var lastFill: [UUID: Fill] = [:]
    func clearFill(_ id: UUID) { lastFill[id] = nil }

    /// Settings speaks in six user-facing words; the store in its nine fields. Estimate,
    /// energy kind and labels ride along with depth / first move / project so nothing is
    /// half-filled.
    static func allowedFields(_ may: Set<CoachTriageField>) -> Set<TriageFieldKind> {
        var out: Set<TriageFieldKind> = []
        if may.contains(.priority) { out.insert(.priority) }
        if may.contains(.effort) { out.formUnion([.effort, .estimateMinutes]) }
        if may.contains(.project) { out.formUnion([.project, .labels]) }
        if may.contains(.depth) { out.formUnion([.depth, .energyKind]) }
        if may.contains(.deadline) { out.insert(.due) }
        if may.contains(.firstMove) { out.insert(.firstMove) }
        return out
    }

    private func examples(excluding id: UUID) -> [TriageExampleSource] {
        let now = Date()
        return model.store.allTasks().filter { $0.id != id && $0.deletedAt == nil }.map { t in
            let age = now.timeIntervalSince(t.updatedAt) / 86_400
            return TriageExampleSource(title: t.title, projectName: t.project?.name, priority: t.priority,
                                       effort: t.effort, depth: t.depth, dueDay: t.dueDay,
                                       open: t.status != .done, recency: 1 / (1 + max(0, age)))
        }
    }
}
