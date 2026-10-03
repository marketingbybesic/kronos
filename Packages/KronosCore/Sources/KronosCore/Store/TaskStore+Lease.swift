// Part of TaskStore: the triage lease.
//
// Every device that sees a task still needing triage would otherwise triage it: two AI calls,
// two fills racing each other, two learned rules. Before triaging, a device claims the task
// (`triageLeaseOwner` + `triageLeaseUntil`, schema V2). A claim held by someone else and not yet
// expired is respected; an expired one may be taken over. The lease is bookkeeping: no undo
// step, and `updatedAt` stays (a claim is not an edit of the task).

import Foundation

public enum TriageLease {
    /// How long one claim lasts.
    public static let duration: TimeInterval = 10 * 60
}

@MainActor
extension TaskStore {

    /// Claim the triage of task `id` for `person` (a device or process name) until
    /// `now + duration`. True when `person` holds the lease afterwards: the task was free, the
    /// previous claim expired, or `person` already held it (the claim is then renewed). False for
    /// a missing task, an empty person, or a live claim by someone else.
    @discardableResult
    public func claimTriageLease(_ id: UUID, owner: String, now: Date = Date(),
                                 duration: TimeInterval = TriageLease.duration) -> Bool {
        guard !owner.isEmpty, let t = task(id) else { return false }
        if let holder = t.triageLeaseOwner, holder != owner,
           let until = t.triageLeaseUntil, until > now {
            return false
        }
        t.triageLeaseOwner = owner
        t.triageLeaseUntil = now.addingTimeInterval(duration)
        saveContext()
        return true
    }

    /// Give the lease back after triage (only the holder can). A no-op otherwise.
    public func releaseTriageLease(_ id: UUID, owner: String) {
        guard let t = task(id), t.triageLeaseOwner == owner else { return }
        t.triageLeaseOwner = nil
        t.triageLeaseUntil = nil
        saveContext()
    }

    /// Who holds a live claim on task `id` at `now`; nil when free or expired.
    public func triageLeaseHolder(_ id: UUID, now: Date = Date()) -> String? {
        guard let t = task(id), let owner = t.triageLeaseOwner,
              let until = t.triageLeaseUntil, until > now else { return nil }
        return owner
    }
}
