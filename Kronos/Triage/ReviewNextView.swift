// Kronos/Triage/ReviewNextView.swift
//
// "Review next": a second way into the same queue ReviewQueue.swift already builds for the full
// Review card (TriageFlowView mode .review / ReviewCardParts.swift) — one item at a time,
// agent-done reports first (an agent waiting on its next move should not sit behind an older
// person-authored proposal; see `ReviewQueue.focusItems`), exactly three actions whatever the
// card's kind: Approve, Request changes (one line, the SAME `AgentReview.reopen`/`reject` the
// full card's own reason field already calls — see `Kronos/Triage/ReviewActions.swift`) and
// Skip — new: this-session-only, nothing written to the store, so a skipped item is simply
// offered again the next time this view opens. No field-editing, no merge, no batch-approve-all:
// those stay the full card's job; this is the fast path, not a replacement.
//
// Same single-card chrome the full Review card and Impuls (Kronos/Impuls/ImpulsScreen.swift)
// both use: one frame (Tok.bg + hairline border, no second inner panel), Metrics.impulsCardWidth,
// KEmptyState for "nothing left". No colour, no motion on the agent byline — ADHD-calm, matching
// the app's pure-black design system.
//
// Entry point: NOT wired here. Like every sibling overlay this is presentation-only
// (`model`/`onClose`); a trigger (sidebar button, palette command, a new `AppModel` bool plus an
// `AppShellView` overlay block mirroring its existing `model.isTriageOpen` one) lives in files
// this change does not own.
import SwiftUI
import KronosCore

struct ReviewNextView: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var items: [ReviewItem] = []
    /// This-session-only skips (Skip never writes to the store): resets the moment this view is
    /// dismissed and reopened, which is the point — nothing was ever decided either way.
    @State private var passed: Set<UUID> = []
    @State private var handled = 0
    @State private var isRequestingChanges = false
    @State private var noteText = ""
    @FocusState private var isNoteFocused: Bool

    private var current: ReviewItem? { items.first { !passed.contains($0.id) } }
    private var remaining: Int { items.filter { !passed.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x5) {
            header
            if let item = current {
                card(for: item)
            } else {
                KEmptyState(icon: "eye", title: String(localized: "review.next.empty"))
                    .uiTestAnchor("review.next.empty")
            }
        }
        .padding(Space.x6)
        .frame(maxWidth: Metrics.impulsCardWidth)
        // The card is ONE frame: this fill and hairline, like the full Review card — nothing
        // inside draws a second border.
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .kBorder(Tok.hairline, radius: Radius.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .uiTestAnchor("review.next.card")
        .onAppear { reload() }
        .onChange(of: model.version) { _, _ in reload() }
        .onChange(of: current?.id) { _, _ in
            isRequestingChanges = false
            noteText = ""
        }
        .onExitCommand(perform: onClose)
    }

    // MARK: Header — "1 of 4", the same wording/format the full Review card uses; never a badge.

    private var header: some View {
        HStack(spacing: Space.x2) {
            Icon("eye", size: Metrics.iconM)
                .foregroundStyle(Tok.textPrimary)
            Text(String(localized: "review.next.title"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            Spacer()
            if current != nil {
                Text(String(format: String(localized: "triage.flow.progress"), handled + 1, handled + remaining))
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
                    .uiTestAnchor("review.next.progress")
            }
        }
    }

    // MARK: Queue

    private func reload() {
        let today = Day.today(calendar: KronosLocale.calendar)
        ReviewSnooze.prune(today: today)
        items = ReviewQueue.focusItems(in: model.store.allTasks(), snoozed: ReviewSnooze.table, today: today)
    }

    /// After every decision (approve, request changes) and after Skip: the item that was on
    /// screen counts as handled either way, for the "N of M" header.
    private func advance() {
        isRequestingChanges = false
        noteText = ""
        if let item = current { passed.insert(item.id); handled += 1 }
        reload()
    }

    // MARK: Card

    @ViewBuilder
    private func card(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            byline(item)
            title(item)
            whatHappened(item)
            if isRequestingChanges {
                noteField(item)
            } else {
                actions(item)
            }
        }
        .id(item.id)
    }

    /// "<Agent> says it is done" / "From <Agent>" — the exact byline ReviewCardParts.swift's own
    /// card uses, same keys, so the two surfaces never read as two different features.
    private func byline(_ item: ReviewItem) -> some View {
        let name = agentName(of: item.primary)
        let line = item.kind == .agentDone
            ? String(format: String(localized: "review.agentdone.says"), name)
            : String(format: String(localized: "review.from"), name)
        return HStack(spacing: Space.x2) {
            Text(line)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .uiTestAnchor("review.next.from")
            if item.context.isUnsure {
                KTag(String(localized: "review.unsure"), tone: Tok.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func agentName(of task: KTask) -> String {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil) {
        case .agent(let name): return name
        case .generic, .none: return String(localized: "review.agent.unnamed")
        }
    }

    private func title(_ item: ReviewItem) -> some View {
        let target = item.kind == .update ? item.context.targetID.flatMap { model.store.task($0) } : nil
        let text = item.kind == .batch ? (item.context.proposalTitle ?? item.primary.title) : (target?.title ?? item.primary.title)
        return Text(text)
            .font(Typo.hero)
            .foregroundStyle(Tok.textPrimary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .uiTestAnchor("review.next.task")
    }

    /// What the agent reported (`resultJSON.note`) for a done task; the proposal's own reason
    /// for everything else — there is no "done" to report on an idea nobody has started yet.
    @ViewBuilder
    private func whatHappened(_ item: ReviewItem) -> some View {
        let text = item.kind == .agentDone ? ReviewResult(json: item.primary.resultJSON).note : item.context.reason
        if let text, !text.isEmpty {
            Text(text)
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .uiTestAnchor("review.next.note")
        }
    }

    // MARK: Decisions — exactly three, always the same three words, whatever the card's kind.
    // The full Review card varies its buttons by kind (Accept/Reopen vs Approve/Edit/Reject/
    // Merge) because it can edit fields and merge duplicates; this card cannot — it is the fast
    // path, not a replacement.

    private func actions(_ item: ReviewItem) -> some View {
        KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
            actionButton(String(localized: "review.action.approve"), anchor: "approve", keyCap: "⏎", kind: .primary) {
                approve(item)
            }
            .keyboardShortcut(.defaultAction)
            actionButton(String(localized: "review.next.request"), anchor: "request") {
                isRequestingChanges = true
                noteText = ""
                DispatchQueue.main.async { isNoteFocused = true }
            }
            actionButton(String(localized: "triage.flow.hint.skip"), anchor: "skip") { advance() }
        }
    }

    private func actionButton(_ label: String, anchor: String, keyCap: String? = nil,
                              kind: KButtonStyle.Kind = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let keyCap {
                HStack(spacing: Space.x2) {
                    Text(label)
                    KKeyCap(keyCap).accessibilityHidden(true)
                }
            } else {
                Text(label)
            }
        }
        .kButton(kind, size: .compact)
        .fixedSize()
        .accessibilityLabel(label)
        .uiTestAnchor("review.next.\(anchor)")
    }

    /// Request changes: one line, the same `AgentReview.reopen`/`reject` the full Review card's
    /// own reason field calls (`ReviewActions.swift`). The first button sends it, the second
    /// sends nothing (Tab's "no reason" meaning on the full card, a tap target here since this
    /// view has no NSEvent key monitor of its own), Esc backs out to the three actions without
    /// closing the card.
    private func noteField(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            KTextField(String(localized: "review.next.note.prompt"), text: $noteText)
                .focused($isNoteFocused)
                .accessibilityLabel(String(localized: "review.next.note.prompt"))
                .uiTestAnchor("review.next.note.field")
            KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
                actionButton(String(localized: "review.next.request"), anchor: "request.commit", kind: .primary) {
                    commitRequest(item, withText: true)
                }
                actionButton(String(localized: "review.hint.noreason"), anchor: "request.noreason") {
                    commitRequest(item, withText: false)
                }
            }
            KKeyHintRow([(["esc"], String(localized: "review.hint.back"))])
        }
        .onSubmit { commitRequest(item, withText: true) }
        .onExitCommand {
            isRequestingChanges = false
            noteText = ""
        }
    }

    // MARK: Store transitions — the SAME `AgentReview` calls `ReviewActions.swift`'s own
    // `reviewApprove()`/`reviewCommitReason(withText:)` make for each kind, including the exact
    // toast wording, so the two surfaces never contradict each other.

    private func approve(_ item: ReviewItem) {
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
            guard AgentReview.approve(item.id, store: store) else { return }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.approved"), title))
        }
        model.didMutate()
        advance()
    }

    private func commitRequest(_ item: ReviewItem, withText: Bool) {
        let store = model.store
        let text = withText ? noteText : ""
        switch item.kind {
        case .agentDone:
            guard AgentReview.reopen(item.id, comment: text, store: store) else { return }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.reopened"), item.primary.title))
        case .batch:
            store.groupedUndo("Reject") {
                for t in item.members { AgentReview.reject(t.id, reason: text, store: store) }
            }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.rejected"),
                                               item.context.proposalTitle ?? item.primary.title))
        case .proposal, .update:
            guard AgentReview.reject(item.id, reason: text, store: store) else { return }
            UndoToastCenter.shared.show(String(format: String(localized: "review.undo.rejected"), item.primary.title))
        }
        model.didMutate()
        advance()
    }
}
