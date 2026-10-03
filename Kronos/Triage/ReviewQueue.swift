// Kronos/Triage/ReviewQueue.swift
//
// The queue behind Review: what agents proposed (reviewRaw 1) and what an agent reports as done
// and waits to be checked (reviewRaw 4). One card per proposal; tasks proposed together
// (same proposal id) are ONE card listing their children. A proposal put off with "not now" is
// out until its day comes. Pure (Foundation + KronosCore, the clock and the snooze table are
// injected) so a hand table can pin it.
import Foundation
import KronosCore

enum ReviewKind: Equatable {
    /// One new task an agent proposed.
    case proposal
    /// Several tasks proposed as one plan.
    case batch
    /// A proposed change to a task the agent does not own (the row is a shadow carrying the patch).
    case update
    /// An agent says the task it was given is done; the person checks.
    case agentDone
}

struct ReviewItem {
    let kind: ReviewKind
    /// The row the card is about (the oldest of a batch).
    let primary: KTask
    /// Every pending task of the proposal, oldest first; just `primary` for a single one.
    let members: [KTask]
    let context: ReviewContext
    var id: UUID { primary.id }
}

enum ReviewQueue {
    static let pending = 1
    static let awaitingCheck = 4

    private static func isCandidate(_ task: KTask) -> Bool {
        guard task.deletedAt == nil, !task.isSubtask else { return false }
        switch task.reviewRaw {
        case pending: return true
        case awaitingCheck: return KStatus.open.contains(task.status)
        default: return false
        }
    }

    private static func isOlder(_ a: KTask, _ b: KTask) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// The card rows, oldest first: one entry per proposal. `snoozed` maps a task id to the day
    /// number it comes back on; a proposal is out while that day is still ahead.
    static func ordered(in tasks: [KTask], snoozed: [UUID: Int], today: Int) -> [KTask] {
        items(in: tasks, snoozed: snoozed, today: today).map(\.primary)
    }

    static func items(in tasks: [KTask], snoozed: [UUID: Int], today: Int) -> [ReviewItem] {
        let live = tasks.filter(isCandidate).sorted(by: isOlder)
        var groups: [UUID: [KTask]] = [:]
        for t in live where t.reviewRaw == pending {
            if let pid = ReviewContext(json: t.contextJSON).proposalID { groups[pid, default: []].append(t) }
        }
        var out: [ReviewItem] = []
        var seenGroups: Set<UUID> = []
        for t in live {
            let ctx = ReviewContext(json: t.contextJSON)
            if t.reviewRaw == awaitingCheck {
                if isHeld(t, group: [t], snoozed, today) { continue }
                out.append(ReviewItem(kind: .agentDone, primary: t, members: [t], context: ctx))
                continue
            }
            if ctx.isUpdate {
                if isHeld(t, group: [t], snoozed, today) { continue }
                out.append(ReviewItem(kind: .update, primary: t, members: [t], context: ctx))
                continue
            }
            if let pid = ctx.proposalID, let group = groups[pid], group.count > 1 {
                guard seenGroups.insert(pid).inserted else { continue }
                if isHeld(group[0], group: group, snoozed, today) { continue }
                out.append(ReviewItem(kind: .batch, primary: group[0], members: group, context: ctx))
                continue
            }
            if isHeld(t, group: [t], snoozed, today) { continue }
            out.append(ReviewItem(kind: .proposal, primary: t, members: [t], context: ctx))
        }
        return out
    }

    /// The open task of the person's own (never another pending one) whose title the proposal
    /// repeats, oldest first: what M merges into.
    static func similarOpen(to task: KTask, in tasks: [KTask]) -> KTask? {
        let key = KTextFold.fold(task.title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return nil }
        return tasks
            .filter {
                $0.id != task.id && $0.deletedAt == nil && $0.reviewRaw != pending && KStatus.open.contains($0.status)
                    && KTextFold.fold($0.title.trimmingCharacters(in: .whitespacesAndNewlines)) == key
            }
            .min { $0.createdAt < $1.createdAt }
    }

    static func count(in tasks: [KTask], snoozed: [UUID: Int], today: Int) -> Int {
        items(in: tasks, snoozed: snoozed, today: today).count
    }

    /// Held while any member's comeback day is still ahead.
    private static func isHeld(_ t: KTask, group: [KTask], _ snoozed: [UUID: Int], _ today: Int) -> Bool {
        group.contains { (snoozed[$0.id] ?? Int.min) > today }
    }
}
