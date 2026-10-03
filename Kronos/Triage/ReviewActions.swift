// Kronos/Triage/ReviewActions.swift
// Everything a key or a click on the Review card does. Each decision is one store transition
// (one undo step, one pill); the agent hears it through the activity log, so nothing here knows
// about agents beyond the proposal's own words.
import SwiftUI
import KronosCore

extension TriageFlowView {

    var isReview: Bool { mode == .review }

    /// The card data for the row on screen (from the list the queue was built from).
    var reviewItem: ReviewItem? {
        guard let current else { return nil }
        return reviewItems.first { $0.id == current.id }
    }

    /// The fields the person changed on this card, named the way the agent's patch names them.
    func editedFieldNames() -> [String] {
        let order: [(TriageField, String)] = [(.priority, "priority"), (.effort, "effort"), (.due, "due"),
                                              (.project, "project"), (.firstMove, "firstMove")]
        return order.filter { lockedFields.contains($0.0) }.map(\.1)
    }

    /// An open task the proposal's title duplicates (never another pending one): the M key merges into it.
    func similarOpenTask(for item: ReviewItem) -> KTask? {
        guard item.kind == .proposal else { return nil }
        return ReviewQueue.similarOpen(to: item.primary, in: model.store.allTasks())
    }

    // MARK: Decisions

    /// Return: approve what the card shows (a batch approves every task of the plan); an
    /// agent-done card accepts the result and closes the task.
    func reviewApprove() {
        guard let item = reviewItem else { onClose(); return }
        let store = model.store
        let title = item.context.proposalTitle ?? item.primary.title
        switch item.kind {
        case .agentDone:
            guard AgentReview.acceptAgentDone(item.id, store: store) else { return }
            KronosSounds.play(.task)
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.accepted"), title))
        case .batch:
            store.groupedUndo("Approve") {
                for t in item.members { AgentReview.approve(t.id, store: store) }
            }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.batch"), item.members.count))
        case .proposal, .update:
            guard AgentReview.approve(item.id, editedFields: editedFieldNames(), store: store) else { return }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.approved"), title))
        }
        decided()
    }

    /// Command-Return: approve every task of the proposal this card belongs to.
    func reviewApproveAll() {
        guard let item = reviewItem, item.kind != .agentDone else { return }
        if item.kind == .batch || item.context.proposalID == nil { reviewApprove(); return }
        let store = model.store
        let n = AgentReview.approveBatch(proposalID: item.context.proposalID!, store: store)
        guard n > 0 else { return }
        let message = n > 1
            ? String(format: String(localized: "review.undo.batch"), n)
            : String(format: String(localized: "review.undo.approved"), item.primary.title)
        UndoToastCenter.shared.show(message)
        decided()
    }

    /// Delete opens the one-line reason field; the agent-done card asks what is missing instead.
    func reviewAskReason() {
        guard let item = reviewItem else { return }
        reasonText = ""
        if item.kind == .agentDone { isReopening = true } else { isRejecting = true }
        DispatchQueue.main.async { isReasonFocused = true }
    }

    func reviewCancelReason() {
        isRejecting = false
        isReopening = false
        reasonText = ""
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Return in the reason field rejects with the typed line, Tab rejects without one.
    func reviewCommitReason(withText: Bool) {
        guard let item = reviewItem else { reviewCancelReason(); return }
        let store = model.store
        let text = withText ? reasonText : ""
        let wasReopening = isReopening
        reviewCancelReason()
        if wasReopening {
            guard AgentReview.reopen(item.id, comment: text, store: store) else { return }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.reopened"), item.primary.title))
        } else {
            store.groupedUndo("Reject") {
                for t in item.members { AgentReview.reject(t.id, reason: text, store: store) }
            }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.rejected"), item.context.proposalTitle ?? item.primary.title))
        }
        decided()
    }

    /// S: not now. The proposal stays pending and hidden; it is offered again tomorrow.
    func reviewSnooze() {
        guard let item = reviewItem else { return }
        let today = Day.today(calendar: KronosLocale.calendar)
        ReviewSnooze.snooze(item.members.map(\.id), until: today + 1)
        let ids = item.members.map(\.id)
        // Nothing changed in the store, so the pill undoes the "not now" itself.
        UndoToastCenter.shared.show(String(format: String(localized: "review.undo.snoozed"), item.context.proposalTitle ?? item.primary.title),
                                    customUndo: { [model] in ReviewSnooze.remove(ids); model.didMutate() })
        decided()
    }

    /// M: fold the proposal into the similar open task, then close the proposal with that reason.
    func reviewMerge() {
        guard let item = reviewItem, let target = similarOpenTask(for: item) else { return }
        let store = model.store
        let t = item.primary
        let proposal = ProposedTask(title: t.title, firstMove: t.firstMove, projectName: t.project?.name, priority: t.priority,
                                    effort: t.effort, dueDay: t.dueDay, notes: t.notes.isEmpty ? nil : t.notes,
                                    subtasks: t.orderedChildren.map(\.title), sourceLine: t.title)
        let name = target.title
        store.groupedUndo("Merge Tasks") {
            store.mergeProposal(proposal, subtasks: proposal.subtasks, into: target.id)
            AgentReview.merge(item.id, into: target.id, reason: String(format: String(localized: "review.merged.reason"), name), store: store)
        }
        UndoToastCenter.shared.show(String(format: String(localized: "review.undo.merged"), name))
        decided()
    }

    /// After any decision: the queue is re-read and the next card shows.
    private func decided() {
        isReviewEditing = false
        model.didMutate()
        advance()
    }

    // MARK: Keys

    /// Review keys. Field keys (1-4, S M L, T W N, D, P, F) only act while E has opened the
    /// fields, which is what frees S (not now) and M (merge) on the plain card.
    func handleReviewKey(_ event: NSEvent) -> Bool {
        if isRejecting || isReopening {
            switch event.keyCode {
            case 36, 76: reviewCommitReason(withText: true); return true
            case 48: reviewCommitReason(withText: false); return true
            case 53: reviewCancelReason(); return true
            default: return false   // the reason field owns every character
            }
        }
        let commandHeld = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76:
            if commandHeld { reviewApproveAll() } else { reviewApprove() }
            return true
        case 53:
            if isReviewEditing { isReviewEditing = false } else { onClose() }
            return true
        case 48: return true   // no skipping: what is not decided now stays in the queue
        case 51, 117: reviewAskReason(); return true
        default: break
        }
        if commandHeld { return false }
        if isReviewEditing, handleEditKey(event) { return true }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let kind = reviewItem?.kind
        switch key {
        case "e" where kind == .proposal: isReviewEditing.toggle()
        case "s": reviewSnooze()
        case "m" where reviewItem.flatMap(similarOpenTask) != nil: reviewMerge()
        case "r" where kind == .agentDone: reviewAskReason()
        default: return false
        }
        return true
    }
}
