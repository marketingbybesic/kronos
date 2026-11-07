// Kronos/Triage/ReviewNextView.swift
//
// "Review next": a second way into the same queue ReviewQueue.swift already builds for the full
// Review card (TriageFlowView mode .review / ReviewCardParts.swift) — one item at a time,
// agent-done reports first (an agent waiting on its next move should not sit behind an older
// person-authored proposal; see `ReviewQueue.focusItems`). Three actions always show — Approve,
// Request changes (one line, the SAME `AgentReview.reopen`/`reject` the full card's own reason
// field already calls — see `Kronos/Triage/ReviewActions.swift`) and Skip, new: this-session-only,
// nothing written to the store, so a skipped item is simply offered again the next time this
// view opens — plus a fourth, conditional one: approve every other pending item from the SAME
// agent in one `groupedUndo` step, shown only when there is more than one. Single-key grammar
// (ReviewNextKeys.swift, an NSEvent monitor like TriageKeys.swift's own): A approve, X request
// changes, S skip, Space expands the agent-done run glance (ReviewNextRunSection.swift —
// summary, artifacts, a static log tail), ⇧A the fourth button. No field-editing, no merge:
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
    /// For the Approve button's keycap (`actionButton` below): the same accent-aware
    /// black/white choice `KButtonStyle` already makes for that button's own label.
    @Environment(\.kAccent) private var accent

    @State private var items: [ReviewItem] = []
    /// This-session-only skips (Skip never writes to the store): resets the moment this view is
    /// dismissed and reopened, which is the point — nothing was ever decided either way.
    @State private var passed: Set<UUID> = []
    @State private var handled = 0
    // Not `private`: ReviewNextKeys.swift's NSEvent monitor reads/writes these directly (same
    // reason TriageFlowView.swift's own @State is never `private` — see its own header note).
    @State var isRequestingChanges = false
    @State var noteText = ""
    @FocusState var isNoteFocused: Bool
    /// The run section (ReviewNextRunSection.swift) is collapsed by default; Space or its own
    /// disclosure button toggles it. Reset whenever the current card changes.
    @State var isRunExpanded = false

    var current: ReviewItem? { items.first { !passed.contains($0.id) } }
    private var remaining: Int { items.filter { !passed.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x5) {
            header
            if let item = current {
                card(for: item)
            } else {
                // A next step, not just a status line, matching the full Review card's own
                // empty state (TriageCardParts.swift's `emptyPanel`): Esc/the scrim already
                // close this card, but a visible action is the one this app's empty states
                // always offer.
                KEmptyState(icon: "eye", title: String(localized: "review.next.empty"),
                            action: .init(title: String(localized: "triage.flow.hint.close"), run: onClose))
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
        .background(TriageKeyCatcher(onKey: handleKey))
        .onAppear { reload() }
        .onChange(of: model.version) { _, _ in reload() }
        .onChange(of: current?.id) { _, _ in
            isRequestingChanges = false
            noteText = ""
            isRunExpanded = false
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
    /// screen counts as handled either way, for the "N of M" header. Draining the queue this
    /// way needs no extra confirmation card — the undo pill (or Skip's own silent pass) already
    /// said what happened — so this closes the overlay itself; only an overlay opened onto an
    /// already-empty queue (`.onAppear`'s own `reload()`) still shows "Nothing waiting on you."
    func advance() {
        isRequestingChanges = false
        noteText = ""
        if let item = current { passed.insert(item.id); handled += 1 }
        reload()
        if current == nil { onClose() }
    }

    // MARK: Card

    @ViewBuilder
    private func card(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            byline(item)
            title(item)
            whatHappened(item)
            runSection(item)
            if isRequestingChanges {
                noteField(item)
            } else {
                actions(item)
            }
        }
        .id(item.id)
    }

    /// "<Agent> says it is done" / "<Agent> exited without reporting" / "From <Agent>" — the
    /// first two match ReviewCardParts.swift's own card byline (same "says it is done" key), so
    /// the two surfaces never read as two different features; the second fires when the agent's
    /// run ended on its own (RunSupervisorEngine's exit-0 fallback, `KAgentRun.
    /// exitedWithoutReporting`) rather than through `run_finish` — "says it is done" would
    /// otherwise claim something the agent never actually said.
    private func byline(_ item: ReviewItem) -> some View {
        let name = agentName(of: item.primary)
        let line: String
        if item.kind == .agentDone {
            let key = exitedWithoutReporting(item) ? "review.agentdone.noreport" : "review.agentdone.says"
            line = String(format: String(localized: String.LocalizationValue(key)), name)
        } else {
            line = String(format: String(localized: "review.from"), name)
        }
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

    /// The latest run on this card's task exited on its own without ever calling `run_finish`
    /// (same lookup `runSection(_:)` already makes for the collapsible run glance).
    private func exitedWithoutReporting(_ item: ReviewItem) -> Bool {
        LiveRuns.runs(taskID: item.primary.id).first?.exitedWithoutReporting == true
    }

    private func agentName(of task: KTask) -> String {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil, resolveDisplayName: Self.agentDisplayName) {
        case .agent(let name): return name
        case .generic, .none: return String(localized: "review.agent.unnamed")
        }
    }

    /// The agent's own stored display name (Settings > Agents), shown verbatim — never
    /// re-capitalised from its slug the way InspectorSourceLabel's own fallback guesses.
    private static func agentDisplayName(slug: String) -> String? {
        let hub = AppDelegate.shared?.mcpLive.hub ?? (try? AgentHub(directory: KronosStore.containerDirectory()))
        return hub?.agent(slug: slug)?.displayName
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

    // MARK: Decisions — Approve, Request changes and Skip always show; a fourth button offers
    // to approve every other pending item from the SAME agent in one step, shown only when
    // there is more than one (ReviewNextKeys.swift's ⇧A does the same thing from the keyboard).
    // The full Review card varies its buttons by kind (Accept/Reopen vs Approve/Edit/Reject/
    // Merge) because it can edit fields and merge duplicates; this card cannot — it is the fast
    // path, not a replacement.

    private func actions(_ item: ReviewItem) -> some View {
        KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
            actionButton(String(localized: "review.action.approve"), anchor: "approve", keyCap: "A", kind: .primary) {
                approve(item)
            }
            .keyboardShortcut(.defaultAction)
            actionButton(String(localized: "review.next.request"), anchor: "request", keyCap: "X") {
                isRequestingChanges = true
                noteText = ""
                DispatchQueue.main.async { isNoteFocused = true }
            }
            actionButton(String(localized: "triage.flow.hint.skip"), anchor: "skip", keyCap: "S") { advance() }
            if let group = approveAllGroup(item) {
                actionButton(String(format: String(localized: "review.next.approveall"), agentName(of: item.primary), group.count),
                            anchor: "approveall", keyCap: "⇧A") {
                    approveAllFromAgent(item)
                }
            }
        }
    }

    private func actionButton(_ label: String, anchor: String, keyCap: String? = nil,
                              kind: KButtonStyle.Kind = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let keyCap {
                HStack(spacing: Space.x2) {
                    Text(label)
                    // The primary Approve button fills with the accent (white by default); the
                    // cap's own default tone, built for the black app ground, goes invisible on
                    // it — give it the SAME black/white choice KButtonStyle already made for
                    // "Approve" itself instead of guessing a second time.
                    KKeyCap(keyCap, tone: kind == .primary ? Accent.onFill(accent) : Tok.textTertiary)
                        .accessibilityHidden(true)
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
    /// own reason field calls (`ReviewActions.swift`). An agent-done card whose agent still has
    /// a working pinned harness (`RunLaunching.canLaunch` == `.available`) also gets "Send back
    /// and run again" — the fast path for "fix this and try again" — shown first and as the
    /// default (Return) action; "Request changes" (reopen only, no relaunch) and "No reason"
    /// stay reachable alongside it for when the person wants to reopen without relaunching. Esc
    /// backs out to the three actions without closing the card.
    private func noteField(_ item: ReviewItem) -> some View {
        let relaunchAgentID = sendBackAgentID(for: item)
        return VStack(alignment: .leading, spacing: Space.x3) {
            KTextField(String(localized: "review.next.note.prompt"), text: $noteText)
                .focused($isNoteFocused)
                .accessibilityLabel(String(localized: "review.next.note.prompt"))
                .uiTestAnchor("review.next.note.field")
            KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
                if let relaunchAgentID {
                    actionButton(String(localized: "review.next.sendback.run"), anchor: "sendback.run", kind: .primary) {
                        commitSendBack(item, agentID: relaunchAgentID)
                    }
                }
                actionButton(String(localized: "review.next.request"), anchor: "request.commit",
                            kind: relaunchAgentID == nil ? .primary : .secondary) {
                    commitRequest(item, withText: true)
                }
                actionButton(String(localized: "review.hint.noreason"), anchor: "request.noreason") {
                    commitRequest(item, withText: false)
                }
            }
            KKeyHintRow([(["esc"], String(localized: "review.hint.back"))])
        }
        .onSubmit {
            if let relaunchAgentID { commitSendBack(item, agentID: relaunchAgentID) }
            else { commitRequest(item, withText: true) }
        }
        .onExitCommand {
            isRequestingChanges = false
            noteText = ""
        }
    }

    /// The agent to relaunch when "Send back and run again" should show: only for an agent-done
    /// card whose agent still has a working pinned harness — nil hides the button entirely
    /// rather than showing it disabled (this card never shows a greyed-out action).
    private func sendBackAgentID(for item: ReviewItem) -> UUID? {
        guard item.kind == .agentDone, let agentID = item.primary.agentID,
              model.runLauncher.canLaunch(agentID: agentID) == .available else { return nil }
        return agentID
    }

    /// Reopens with the typed comment (the same `AgentReview.reopen` "Request changes" calls)
    /// then relaunches the same agent on the same task — `HandoffAndRun.attempt`'s own
    /// check-then-launch shape, minus the delegate write: the task is already this agent's, so
    /// there is nothing to hand off, only the reopen and the launch. The reopen's own toast
    /// covers this action too; the launch has no toast of its own anywhere else in the app.
    private func commitSendBack(_ item: ReviewItem, agentID: UUID) {
        let store = model.store
        guard AgentReview.reopen(item.id, comment: noteText, store: store) else { return }
        try? model.runLauncher.launch(taskID: item.primary.id, agentID: agentID,
                                      model: HandoffModelPrefs.lastUsed(agentID: agentID))
        UndoToastCenter.shared.show(String(format: String(localized: "review.undo.reopened"), item.primary.title))
        model.didMutate()
        advance()
    }

    // MARK: Store transitions — the SAME `AgentReview` calls `ReviewActions.swift`'s own
    // `reviewApprove()`/`reviewCommitReason(withText:)` make for each kind, including the exact
    // toast wording, so the two surfaces never contradict each other.

    func approve(_ item: ReviewItem) {
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

    // MARK: ⇧A — approve every other pending item from the same agent

    /// Every other pending item from the SAME agent (current included) — nil when there is
    /// only one, so the button never offers to "approve all" of itself. The grouping DECISION
    /// is `AgentTeamSignals.bulkApproveGroup` (KronosCore, table-tested); this only maps
    /// `ReviewItem`s to the `(id, agentID)` pairs it needs and maps the result back.
    private func approveAllGroup(_ item: ReviewItem) -> [ReviewItem]? {
        guard let agentID = item.primary.agentID else { return nil }
        let pending = items.filter { !passed.contains($0.id) }
        guard let groupIDs = AgentTeamSignals.bulkApproveGroup(
            itemAgentIDs: pending.map { ($0.id, $0.primary.agentID) }, targetAgentID: agentID) else { return nil }
        let idSet = Set(groupIDs)
        return pending.filter { idSet.contains($0.id) }
    }

    /// One `groupedUndo` step for the whole agent's queue, the same per-kind store calls
    /// `approve(_:)` makes for one item.
    func approveAllFromAgent(_ item: ReviewItem) {
        guard let group = approveAllGroup(item) else { approve(item); return }
        let store = model.store
        let name = agentName(of: item.primary)
        store.groupedUndo("Approve") {
            for g in group {
                switch g.kind {
                case .agentDone: AgentReview.acceptAgentDone(g.id, store: store)
                case .batch: for t in g.members { AgentReview.approve(t.id, store: store) }
                case .proposal, .update: AgentReview.approve(g.id, store: store)
                }
            }
        }
        for g in group { passed.insert(g.id) }
        handled += group.count
        UndoToastCenter.shared.show(String(format: String(localized: "review.next.approveall.undo"), group.count, name))
        model.didMutate()
        reload()
        // Same "drained by MY action, not opened onto nothing" rule as advance() above:
        // approving the rest of the agent's queue in one step is itself the confirmation.
        if current == nil { onClose() }
    }
}
