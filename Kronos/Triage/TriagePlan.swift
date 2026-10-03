// Kronos/Triage/TriagePlan.swift
//
// What pressing Return on a triage card is allowed to write, decided in one pure place so the
// card, its "also fills" line and the tests all read the same answer. Foundation + KronosCore
// only, so scripts/triage-lock-selftest.swift compiles this file next to a hand-written table.
import Foundation
import KronosCore

/// One sitting is at most five cards: a short, finishable burst instead of a counter that
/// shows the whole backlog.
enum TriageSession {
    static let size = 5

    /// "2 of 5": the position is cards already handled in this sitting plus one, the total is
    /// the sitting size or fewer when the queue is shorter. Nil when nothing is left to show.
    static func progress(handled: Int, remaining: Int) -> (position: Int, total: Int)? {
        guard remaining > 0, handled < size else { return nil }
        return (handled + 1, min(size, handled + remaining))
    }

    static func isOver(handled: Int) -> Bool { handled >= size }
}

enum TriagePlan {
    /// Fields the card shows as editable rows (the first move sits above them).
    static let shownFields: [TriageFieldKind] = [.priority, .effort, .due, .project, .firstMove]
    /// Fields the card names in its "also fills" line instead of showing them as rows.
    /// Labels are never offered to the model, so they are never written from here.
    static let listedFields: [TriageFieldKind] = [.depth, .estimateMinutes, .energyKind]

    /// Everything the decision depends on besides the task and the result.
    struct Limits {
        /// The Settings > Coach fields the person lets triage fill; nil = all.
        var allowed: Set<TriageFieldKind>?
        /// Fields a neighbour vote really decided; nil = the result is not a placeholder vote
        /// (an AI answer), so every field in it counts.
        var fillable: Set<TriageFieldKind>?
        var today: Int
        var projectNames: [String]
        /// Fields picked by hand on this card: never replaced by the suggestion, not even by
        /// an explicit "none".
        var pickedByHand: Set<TriageFieldKind> = []
    }

    /// The fields Return writes: only ones that are shown or listed, empty on the task, not
    /// locked, allowed by Settings, decided by the source and carrying a usable value.
    static func writes(_ result: TriageResult, on task: KTask, _ limits: Limits) -> Set<TriageFieldKind> {
        var out: Set<TriageFieldKind> = []
        let locked = task.lockedFields
        for field in shownFields + listedFields {
            if locked.contains(field) || limits.pickedByHand.contains(field) { continue }
            if let allowed = limits.allowed, !allowed.contains(field) { continue }
            if let fillable = limits.fillable, !fillable.contains(field) { continue }
            guard isEmpty(field, on: task), hasValue(field, in: result, task: task, limits) else { continue }
            out.insert(field)
        }
        return out
    }

    /// The listed (not shown) fields that Return will write, in display order.
    static func alsoFills(_ writes: Set<TriageFieldKind>) -> [TriageFieldKind] {
        listedFields.filter(writes.contains)
    }

    /// The suggested deadline as a day number. A date before today is never suggested: Return
    /// would otherwise commit a deadline that is already missed.
    static func suggestedDue(_ result: TriageResult, today: Int) -> Int? {
        guard let due = result.due, let day = Day.parseISO(due), day >= today else { return nil }
        return day
    }

    /// The suggested project when it names an existing one, matched like `applyTriage` does.
    static func suggestedProject(_ result: TriageResult, in projects: [KProject]) -> KProject? {
        guard let name = result.project else { return nil }
        return projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The suggested first move unless it only repeats the task title.
    static func suggestedFirstMove(_ result: TriageResult, for task: KTask) -> String? {
        let move = result.firstMove.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !move.isEmpty, !FirstMoveRestatement.restates(move, title: task.title) else { return nil }
        return move
    }

    private static func isEmpty(_ field: TriageFieldKind, on task: KTask) -> Bool {
        switch field {
        case .project: task.project == nil
        case .priority: task.priority == .none
        case .due: task.dueDay == nil
        case .depth: task.depth == .unknown
        case .estimateMinutes: task.estimateMinutes == nil
        case .energyKind: task.energyKind == nil
        case .firstMove: task.firstMove == nil
        case .labels: (task.labels ?? []).isEmpty
        case .effort: task.effort == .none
        }
    }

    private static func hasValue(_ field: TriageFieldKind, in result: TriageResult, task: KTask, _ limits: Limits) -> Bool {
        switch field {
        case .project:
            guard let name = result.project else { return false }
            return limits.projectNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        case .priority: return result.priority > 0 && KPriority(rawValue: result.priority) != nil
        case .effort: return result.effort != nil && result.effort != KEffort.none
        case .due: return suggestedDue(result, today: limits.today) != nil
        case .firstMove: return suggestedFirstMove(result, for: task) != nil
        case .depth, .energyKind: return true
        case .estimateMinutes: return result.estimateMinutes > 0
        case .labels: return false
        }
    }
}
