// Kronos/Triage/TriageActions.swift. Split out of TriageFlowView.swift (500-line lint gate).
// Everything a key or a click on the card writes to the store.
import SwiftUI
import KronosCore

extension TriageFlowView {

    enum QuickDeadline { case today, tomorrow, thisWeek, none }

    // MARK: What Return writes

    /// The limits `TriagePlan` applies on the card on screen: Settings > Coach fields, the
    /// fields the vote really decided, today, the projects that exist, and what was picked by hand.
    func planLimits() -> TriagePlan.Limits {
        TriagePlan.Limits(
            allowed: AutoTriage.allowedFields(model.coach.settings.triageMayFill),
            fillable: suggestionSource == .ai ? nil : fillable,
            today: Day.today(calendar: KronosLocale.calendar),
            projectNames: model.store.allProjects().map(\.name),
            pickedByHand: Set(lockedFields.compactMap { TriageFieldKind(rawValue: $0.rawValue) }))
    }

    /// The fields Return would write on `task` right now; empty without a suggestion.
    func plannedWrites(for task: KTask) -> Set<TriageFieldKind> {
        guard let suggestion else { return [] }
        return TriagePlan.writes(suggestion, on: task, planLimits())
    }

    // MARK: Hand picks

    func setPriority(_ p: KPriority) {
        guard let current else { return }
        lockedFields.insert(.priority)
        model.store.setPriority(current.id, p)
        model.didMutate()
    }

    func setEffort(_ e: KEffort) {
        guard let current else { return }
        lockedFields.insert(.effort)
        model.store.setEffort(current.id, e)
        model.didMutate()
    }

    /// A project chosen in the picker (key P or a click on the Project field): locks the field against the
    /// AI suggestion, files the task with one undo step, closes the picker.
    func pickProject(_ project: KProject?) {
        isPickingProject = false
        guard let current else { return }
        lockedFields.insert(.project)
        guard current.projectID != project?.id else { return }
        model.store.move(current.id, toProject: project)
        model.didMutate()
    }

    func setDeadline(_ d: QuickDeadline) {
        guard let current else { return }
        lockedFields.insert(.due)
        let today = Day.today(calendar: KronosLocale.calendar)
        let day: Int?
        switch d {
        case .today: day = today
        case .tomorrow: day = today + 1
        case .thisWeek: day = today + 7
        case .none: day = nil
        }
        model.store.setDue(current.id, day: day)
        model.didMutate()
    }

    /// The first move is typed on the card itself (F or a click on its line); Return commits.
    func openMoveField() {
        guard let current else { return }
        moveText = current.firstMove ?? (suggestion.flatMap { TriagePlan.suggestedFirstMove($0, for: current) } ?? "")
        isEditingMove = true
        DispatchQueue.main.async { isMoveFieldFocused = true }
    }

    func commitMove(for task: KTask) {
        let trimmed = moveText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { isEditingMove = false }
        lockedFields.insert(.firstMove)
        model.store.setFirstMove(task.id, trimmed.isEmpty ? nil : trimmed)
        model.didMutate()
    }

    // MARK: Sort: accept / skip

    /// Return: apply exactly the fields the card shows or lists (fill-only: never overwrites a
    /// field already touched this card, in the store or with a key press above) in one undo
    /// step, then advance. In Sweep, Return keeps the task.
    func acceptAndNext() {
        guard let current else { onClose(); return }
        if isSweep { sweep(.keep); return }
        if let suggestion {
            let filled = model.store.applyTriage(suggestion, to: current.id, fillOnly: true, only: plannedWrites(for: current))
            // Provenance, like automatic triage: exactly these fields, from this source.
            if !filled.isEmpty {
                let modelName = (model.ai as? AIRouter)?.candidates.first?.client.modelID
                model.store.recordTriageFill(task: current.id, fields: filled,
                                             model: suggestionSource == .ai ? modelName : "neighbours")
            }
        } else {
            model.store.update(current.id) { $0.needsTriage = false }
        }
        model.didMutate()
        advance()
    }

    func skip() { advance() }

    // MARK: Sweep

    /// One sweep decision. Every change that is not a plain "keep" is one undo step and raises
    /// the undo pill; keeping only stamps the task as looked at (no undo step, nothing changed).
    func sweep(_ action: SweepAction) {
        guard let task = current else { return }
        let store = model.store
        let title = task.title
        let today = Day.today(calendar: KronosLocale.calendar)
        switch action {
        case .keep:
            store.updateNoUndo(task.id) { $0.updatedAt = Date() }
        case .planToday:
            store.groupedUndo("Sweep") {
                if !KStatus.active.contains(task.status) { store.setStatus(task.id, .todo) }
                store.plan(task.id, day: today)
            }
            UndoToastCenter.shared.show(String(format: String(localized: "sweep.undo.today"), title))
        case .someday:
            if task.status == .someday {
                store.updateNoUndo(task.id) { $0.updatedAt = Date() }
            } else {
                store.groupedUndo("Sweep") {
                    store.setStatus(task.id, .someday)
                    if task.plannedDay != nil { store.plan(task.id, day: nil) }
                }
                UndoToastCenter.shared.show(String(format: String(localized: "sweep.undo.someday"), title))
            }
        case .delete:
            store.softDelete(task.id)
            UndoToastCenter.shared.show(String(format: String(localized: "undo.deleted.name"), title))
        case .done:
            store.complete(task.id)
            UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), title))
        }
        model.didMutate()
        advance()
    }
}
