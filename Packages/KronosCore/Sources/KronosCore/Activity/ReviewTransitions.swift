// The person's decisions on what agents propose, as store operations. The review UI calls these;
// each one is a single undo step. Events for the agent follow from the log's sync, so the UI
// needs no knowledge of agents.
//
//   reviewRaw: 0 none, 1 pending, 2 approved, 3 rejected, 4 done by the agent, awaiting a check

import Foundation

public enum ReviewState {
    public static let none = 0
    public static let pending = 1
    public static let approved = 2
    public static let rejected = 3
    public static let awaitingCheck = 4
}

@MainActor
public enum AgentReview {

    /// The person's verdict, as `AgentTaskResult.verdict` carries it.
    public static let accepted = "accepted"
    public static let rejectedVerdict = "rejected"

    private static func record(_ result: inout AgentTaskResult, _ verdict: String, comment: String?, at: Date) {
        result.verdict = verdict
        result.verdictComment = comment
        result.verdictAt = at
    }

    /// Approves a pending proposal. A proposed update applies its patch to the target; the task
    /// itself simply becomes visible. `editedFields` names what the person changed on the card.
    @discardableResult
    public static func approve(_ id: UUID, editedFields: [String] = [], store: any TaskStoring) -> Bool {
        guard let t = store.task(id), t.reviewRaw == ReviewState.pending else { return false }
        let ctx = AgentContext.decode(t.contextJSON)
        var result = AgentTaskResult()
        result.by = "me"
        result.decision = editedFields.isEmpty ? "approve" : "edit"
        record(&result, accepted, comment: nil, at: Date())
        result.editedFields = editedFields.isEmpty ? nil : editedFields
        store.groupedUndo("Approve") {
            if let u = ctx?.update, ctx?.isUpdate == true {
                AgentPatch.apply(u.patch, to: u.targetID, store: store)
                store.update(id) { $0.reviewRaw = ReviewState.approved; $0.resultJSON = result.encoded() }
                store.softDelete(id)   // the proposal row is spent
            } else {
                store.update(id) { $0.reviewRaw = ReviewState.approved; $0.resultJSON = result.encoded() }
            }
        }
        return true
    }

    /// Approves every pending task of one proposal.
    @discardableResult
    public static func approveBatch(proposalID: UUID, store: any TaskStoring) -> Int {
        let ids = store.allTasksIncludingSubtasks().filter {
            $0.reviewRaw == ReviewState.pending && AgentContext.decode($0.contextJSON)?.proposalID == proposalID
        }.map(\.id)
        var n = 0
        store.groupedUndo("Approve") { for id in ids where approve(id, store: store) { n += 1 } }
        return n
    }

    /// Rejects a pending proposal: the row leaves every list and the agent hears the reason.
    @discardableResult
    public static func reject(_ id: UUID, reason: String?, store: any TaskStoring) -> Bool {
        guard let t = store.task(id), t.reviewRaw == ReviewState.pending else { return false }
        var result = AgentTaskResult()
        result.by = "me"
        result.outcome = "rejected"
        result.decision = "reject"
        result.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let why = result.reason
        record(&result, rejectedVerdict, comment: why, at: Date())
        store.groupedUndo("Reject") {
            store.update(id) { $0.reviewRaw = ReviewState.rejected; $0.resultJSON = result.encoded() }
            store.softDelete(id)
        }
        return true
    }

    /// Folds a pending proposal into an open task that already covers it: the proposal row is
    /// spent (it leaves every list) and the agent hears an approval with decision "merge" naming
    /// the task it went into, not a rejection. The caller moves the proposal's content into the
    /// target first (inside the same undo group); this only closes the proposal.
    @discardableResult
    public static func merge(_ id: UUID, into targetID: UUID, reason: String?, store: any TaskStoring) -> Bool {
        guard id != targetID, let t = store.task(id), t.reviewRaw == ReviewState.pending,
              store.task(targetID) != nil else { return false }
        var result = AgentTaskResult()
        result.by = "me"
        result.decision = "merge"
        result.mergedInto = targetID
        result.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let why = result.reason
        record(&result, accepted, comment: why, at: Date())
        store.groupedUndo("Merge") {
            store.update(id) { $0.reviewRaw = ReviewState.approved; $0.resultJSON = result.encoded() }
            store.softDelete(id)
        }
        return true
    }

    /// Accepts what an agent reports as done: the task closes with the agent's own note. An optional
    /// `comment` is the person's word with the verdict; the agent reads it in `get_task` and `events_poll`.
    @discardableResult
    public static func acceptAgentDone(_ id: UUID, comment: String? = nil, store: any TaskStoring, now: Date = Date()) -> Bool {
        guard let t = store.task(id), t.reviewRaw == ReviewState.awaitingCheck else { return false }
        let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var result = AgentTaskResult.decode(t.resultJSON) ?? AgentTaskResult()
        result.by = "me"
        result.outcome = "done"
        result.completedAt = now
        record(&result, accepted, comment: text, at: now)
        var ctx = AgentContext.decode(t.contextJSON) ?? AgentContext()
        if let text { ctx.append(comment: .init(at: now, by: "me", text: text)) }
        let context = text == nil ? t.contextJSON : ctx.encoded()
        store.groupedUndo("Accept") {
            store.update(id) { $0.reviewRaw = ReviewState.approved; $0.resultJSON = result.encoded(); $0.contextJSON = context }
            store.complete(id)
        }
        return true
    }

    /// Sends an agent's "done" back: the task stays open and the agent hears why.
    @discardableResult
    public static func reopen(_ id: UUID, comment: String?, store: any TaskStoring, now: Date = Date()) -> Bool {
        guard let t = store.task(id), t.reviewRaw == ReviewState.awaitingCheck else { return false }
        let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var result = AgentTaskResult()
        result.by = "me"
        result.outcome = "reopened"
        result.note = text
        record(&result, rejectedVerdict, comment: text, at: now)
        var ctx = AgentContext.decode(t.contextJSON) ?? AgentContext()
        if let text { ctx.append(comment: .init(at: now, by: "me", text: text)) }
        store.groupedUndo("Reopen") {
            store.update(id) {
                $0.reviewRaw = ReviewState.none
                $0.resultJSON = result.encoded()
                $0.contextJSON = ctx.encoded()
            }
        }
        return true
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
