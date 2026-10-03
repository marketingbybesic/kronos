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

    /// The running service (the app starts exactly one). The inspector reads it from here so a
    /// host that starts its own instance, such as the live UI test, is seen by the same views.
    private(set) static weak var live: AutoTriage?

    func start() {
        AutoTriage.live = self
        observer = NotificationCenter.default.addObserver(forName: .kronosTaskDidCreate, object: nil,
                                                          queue: .main) { [weak self] note in
            guard let id = note.userInfo?["taskID"] as? UUID else { return }
            MainActor.assumeIsolated { self?.triage(id, automatic: true) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if AutoTriage.live === self { AutoTriage.live = nil }
    }

    /// Also the entry point for "Re-triage" (fill-only by default).
    ///
    /// `automatic` marks the run started by a task's creation. Such a run only touches a task
    /// that still asks for triage: MCP, agent and capture creations that say `triage: false`
    /// (the default for MCP) are left exactly as they were written, and a task that carries a
    /// machine `source` is filled without an undo step so it can never bury the person's own
    /// last action. A deliberate Re-triage is the person's own action and always undoable.
    func triage(_ id: UUID, fillOnly: Bool = true, automatic: Bool = false) {
        guard isEnabled || !fillOnly, let task = model.store.task(id), !task.isSubtask else { return }
        let title = task.title, notes = task.notes
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let today = Day.today()
        let context = TriageContextBuilder.build(for: title, notes: notes, from: examples(excluding: id))
        let projectNames = model.store.allProjects(includeArchived: false).map(\.name)
        let labelNames = model.store.labels().map(\.name)
        let router = model.ai
        let lockedNames = model.store.lockedFields(of: id).map(\.rawValue)
        let modelName = (router as? AIRouter)?.candidates.first?.client.modelID

        Task { @MainActor [weak self] in
            guard let self else { return }
            // The creating code may still be filling the task in (an MCP create sets its
            // `triage` flag right after the row exists), so eligibility is read here, after
            // the creating call has returned, and again once the model has answered.
            guard self.isEligible(id, automatic: automatic) else { return }
            // Another device (or process) triaging this task right now holds its lease: leave
            // the task to it. The lease is given back however this run ends.
            let leaseOwner = Self.leaseOwner
            guard self.model.store.claimTriageLease(id, owner: leaseOwner) else { return }
            defer { self.model.store.releaseTriageLease(id, owner: leaseOwner) }
            var result = NeighbourTriage.infer(title: title, notes: notes, context: context, today: today)
            let neighbourFields = NeighbourTriage.fillableFields(title: title, notes: notes,
                                                                 context: context, today: today)
            var isNeighbourSourced = true
            if let router,
               let ai = try? await router.triage(title: title, notes: notes, projectNames: projectNames,
                                                 labelNames: labelNames, today: today, lockedFields: Set(lockedNames),
                                                 context: context) {
                result = ai
                // The router's own last resort is the neighbour vote: its reason keeps the fixed
                // English shape and its placeholders must stay unwritten.
                isNeighbourSourced = ai.isDeterministic
            }
            // The task may have been edited or deleted while the model was thinking: fill-only
            // keeps anything typed in the meantime, and a missing task is simply skipped.
            guard self.isEligible(id, automatic: automatic), let current = self.model.store.task(id) else { return }
            var allowed = Self.allowedFields(self.model.coach.settings.triageMayFill)
            // A neighbour vote carries neutral placeholders for the fields it did not decide
            // (depth, estimate, energy kind): those stay empty rather than being invented.
            if result.isDeterministic { allowed.formIntersection(neighbourFields) }
            let machineOrigin = TriageEligibility.fillsWithoutUndo(automatic: automatic, source: current.source)
            let dreadBefore = current.dread
            let filled = machineOrigin
                ? self.model.store.applyTriageWithoutUndo(result, to: id, fillOnly: fillOnly, only: allowed)
                : self.model.store.applyTriage(result, to: id, fillOnly: fillOnly, only: allowed)
            // The model's dread judgement is applied with the fill but is not one of its fields.
            let dreadChanged = self.model.store.task(id)?.dread != dreadBefore
            guard !filled.isEmpty || dreadChanged else { return }
            if !filled.isEmpty {
                // Provenance: exactly these fields, from this source, so Discard can undo only them.
                self.model.store.recordTriageFill(task: id, fields: filled,
                                                  model: isNeighbourSourced ? "neighbours" : modelName)
                self.lastFill[id] = Fill(fields: filled, reason: result.reason, isNeighbourSourced: isNeighbourSourced)
            }
            self.model.didMutate()
        }
    }

    /// Who this process is when it claims a triage lease: the device id (shared by every Kronos
    /// process on this Mac) plus the process id, so the app and a background instance never
    /// triage the same task at once either.
    static var leaseOwner: String {
        let device = DeviceOrigin.current?.id ?? "device"
        return device + "." + String(ProcessInfo.processInfo.processIdentifier)
    }

    private func isEligible(_ id: UUID, automatic: Bool) -> Bool {
        guard let task = model.store.task(id) else { return false }
        return TriageEligibility.mayRun(automatic: automatic, needsTriage: task.needsTriage)
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
