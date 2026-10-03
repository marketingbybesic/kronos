// Kronos/Triage/TriageFlowView.swift
//
// A simple way to triage tasks: go in order through every task missing data, with an
// automated suggestion for each one — as little initiation energy as possible, in service of
// the app's broader ADHD-friendly automation goal. So: ONE task, the suggestion is already
// filled in, Return accepts everything and moves on. No red, no streaks, no pressure copy —
// progress reads as "3 of 5", never a badge (see ui-common.md / art-direction.md). A sitting
// is five cards (TriageSession); the same card flow also runs Sweep (TriageMode.sweep).
//
// Key dispatch is an NSEvent local monitor, not SwiftUI focus: see TriageKeys.swift for the
// root cause. Card parts live in TriageCardParts.swift, the write actions in TriageActions.swift,
// the AI lifecycle in TriageAIState.swift, the field menus in TriageFieldMenus.swift.
import SwiftUI
import KronosCore

/// ONE task at a time from `TriageQueue.ordered` (or `SweepQueue.ordered`), suggestion
/// pre-filled from `NeighbourTriage.infer` (upgraded by `model.ai?.triage` when it answers),
/// applied through `store.applyTriage(_:to:fillOnly:only:)` with exactly the fields
/// `TriagePlan.writes` names — the same call `AutoTriage` uses, so a triage applied here is
/// undoable and marked exactly like an automatic one.
struct TriageFlowView: View {
    let model: AppModel
    @Environment(\.kAccent) private var accent
    let onClose: () -> Void
    /// Snapshot-only seam (default false, every real call site is unaffected): starts the card
    /// with the date field already open, for the `triage.card.date` named screen — the D key
    /// interaction itself cannot be exercised by a static render.
    var startWithDateEditing = false
    /// Snapshot-only seam: shows this mode instead of the pending launch request.
    var startMode: TriageMode?
    /// Snapshot-only seam: starts with this many cards of the sitting already handled.
    var startHandled = 0
    /// Snapshot-only seam: opens the reason field of the first Review card.
    var startRejecting = false
    /// Snapshot-only seam: the key legend starts open (as while ⌥ is held).
    var startLegendOpen = false

    // Not `private`: the TriageFieldMenus / TriageAIState / TriageActions / TriageKeys /
    // TriageCardParts extensions (same target, split out to keep each file under the 500-line
    // lint gate) read and write this state directly — `private` would be a same-file
    // restriction those files do not share, and `fileprivate` does not cross files either.
    @State var mode: TriageMode = .sort
    @State var queue: [KTask] = []
    @State var index = 0
    /// Tasks already accepted or skipped in THIS flow. Without it Tab never left the card and
    /// Return only did when the task ended up with all four fields: the queue was re-derived
    /// from the store and the same task came back first, reading as keys doing nothing.
    @State var passed: Set<UUID> = []
    /// Cards finished in the current sitting of five; "Do 5 more" starts the next one.
    @State var handled = 0
    @State var suggestion: TriageResult?
    @State var suggestionSource: SuggestionSource?
    /// Fields the neighbour vote really decided (nil once an AI answer replaced it).
    @State var fillable: Set<TriageFieldKind>?
    @State var isAskingAI = false
    @State var isEditingDate = false
    @State var dateText = ""
    @FocusState var isDateFieldFocused: Bool
    /// The project picker popover is open (key P, or a click on the Project field): it owns the keyboard.
    @State var isPickingProject = false
    @State var isEditingMove = false
    @State var moveText = ""
    @FocusState var isMoveFieldFocused: Bool
    /// Fields picked by hand on this card (key or menu): a re-vote or a slower AI reply must
    /// never replace them, and Return never writes them again. Cleared on every card change.
    @State var lockedFields: Set<TriageField> = []
    /// The calm failure line shown once `askAI` observes a thrown error or the router's own
    /// silent fallback (`TriageResult.isDeterministic`). `nil` = no failure to show.
    @State var aiFailure: AIFailureReason?
    /// Seconds since the current AI ask started, driving "Asking AI… 3s".
    @State var askingElapsed = 0
    /// Identifies the in-flight ask so a Refresh (or a card change) makes any EARLIER reply for
    /// this task a no-op instead of racing the newer one onto screen.
    @State var askID = UUID()
    @State var elapsedTimer: Timer?
    /// Review mode: the cards the queue was built from (one per proposal), the open fields
    /// (E), and the one-line reason field of Delete (reject) or R (reopen).
    @State var reviewItems: [ReviewItem] = []
    @State var isReviewEditing = false
    @State var isRejecting = false
    @State var isReopening = false
    @State var reasonText = ""
    @FocusState var isReasonFocused: Bool

    /// Which path produced `suggestion`, so a same-tick neighbour vote can be told apart from
    /// a slower model upgrade that replaced it.
    enum SuggestionSource { case neighbours, ai }

    init(model: AppModel, onClose: @escaping () -> Void, startWithDateEditing: Bool = false,
         startMode: TriageMode? = nil, startHandled: Int = 0, startRejecting: Bool = false,
         startLegendOpen: Bool = false) {
        self.model = model
        self.onClose = onClose
        self.startWithDateEditing = startWithDateEditing
        self.startMode = startMode
        self.startHandled = startHandled
        self.startRejecting = startRejecting
        self.startLegendOpen = startLegendOpen
    }

    /// Settings > AI switch ("Use AI suggestions when sorting"); read live so a change made
    /// in Settings applies to the card on screen at its next refresh.
    var aiEnabled: Bool { TriagePrefs.aiSuggestionsEnabled }
    var isSweep: Bool { mode == .sweep }
    var current: KTask? { index < queue.count ? queue[index] : nil }
    var sessionOver: Bool { !isReview && TriageSession.isOver(handled: handled) && !queue.isEmpty }

    var body: some View {
        ZStack {
            // No full-window `Tok.bg` here: the shell's scrim already dims the list, and an
            // opaque fill turned the whole window black behind the card (live audit 30.09.),
            // unlike every sibling overlay (Impuls/Capture/palette) which keeps the context.
            VStack(alignment: .leading, spacing: Space.x5) {
                header
                if sessionOver {
                    sessionPanel
                } else if let current {
                    if isSweep { sweepCard(for: current) } else if isReview { reviewCard(for: current) } else { card(for: current) }
                } else {
                    emptyPanel
                }
            }
            .padding(Space.x6)
            .frame(maxWidth: Metrics.impulsCardWidth)
            // The card is ONE frame: this fill and hairline. Nothing inside draws a second
            // border (the old inner panel did, a frame within a frame).
            .background(Tok.bg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .kBorder(Tok.hairline, radius: Radius.card)
        }
        // The shell's overlay pins this view to the top like the palette; filling the whole
        // overlay region and centering HERE puts the tall card in the true middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .uiTestAnchor("triage.card")
        // Every key comes from a local NSEvent monitor, not SwiftUI `.onKeyPress`/`@FocusState`
        // (see TriageKeys.swift).
        .background(TriageKeyCatcher(onKey: handleKey))
        .onAppear {
            mode = startMode ?? TriageLaunch.shared.consume()
            handled = startHandled
            reload()
            // Whatever HAD first responder before this card appeared (e.g. quick add's text
            // field) is resigned up front so the card's first click on any menu is never eaten.
            if !startWithDateEditing { NSApp.keyWindow?.makeFirstResponder(nil) }
            if startRejecting { DispatchQueue.main.async { reviewAskReason() } }
            if startWithDateEditing {
                // Deferred past the SAME tick: `reload()` just took `current` from nil to the
                // first queued task, and `.onChange(of: current?.id)` resets `isEditingDate`.
                DispatchQueue.main.async { openDateField() }
            }
        }
        .onChange(of: TriageLaunch.shared.token) { _, _ in
            // Sweep chosen from the palette while the card is already open: switch in place.
            mode = TriageLaunch.shared.consume()
            handled = 0
            passed = []
            reload()
        }
        .onChange(of: model.version) { _, _ in
            // A background triage or an edit elsewhere may have changed what still qualifies:
            // re-derive the queue but keep the current task's place in it if it is still there.
            let keepID = current?.id
            queue = freshQueue()
            if let keepID, let kept = queue.firstIndex(where: { $0.id == keepID }) {
                index = kept
            } else {
                // The card's task left the queue because the edit filled it in: that card is done.
                if let keepID, !passed.contains(keepID) { passed.insert(keepID); handled += 1 }
                queue = freshQueue()
                index = min(index, max(queue.count - 1, 0))
            }
            if current == nil { suggestion = nil } else if suggestion == nil { loadSuggestion() }
        }
        .onChange(of: current?.id) { _, _ in
            isEditingDate = false
            isPickingProject = false
            isEditingMove = false
            isReviewEditing = false
            isRejecting = false
            isReopening = false
            lockedFields = []
        }
        // Swapping the date field for a menu does not make AppKit resign the hidden field
        // editor's NSTextView; the next click would be eaten by that bookkeeping. Resign
        // explicitly the moment either text field stops being the logical focus target.
        .onChange(of: isEditingDate) { _, editing in
            guard !editing else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: isEditingMove) { _, editing in
            guard !editing else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        // The picker's popover closes with a field editor still the window's first responder: the next
        // P (or any card key) would be taken as typing. Hand the keyboard back to the card.
        .onChange(of: isPickingProject) { _, picking in
            guard !picking, !isEditingDate, !isEditingMove else { return }
            if let window = NSApp.keyWindow, window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        }
    }

    // MARK: Header — "3 of 5", never a badge; the leading mark is the one hue (accent, white in Focus).

    private var header: some View {
        HStack(spacing: Space.x2) {
            KViewMark(icon: isSweep ? "archive" : (isReview ? "eye" : "check-square"),
                      tint: SelectionHue.resolve(projectHex: nil, neutral: model.chromaMode.isNeutralSelection).color(accent: accent), size: Metrics.iconM)
            Text(String(localized: isSweep ? "sweep.card.title" : (isReview ? "review.card.title" : "triage.card.title")))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            Spacer()
            if !sessionOver, let progress = headerProgress {
                Text(String(format: String(localized: "triage.flow.progress"), progress.position, progress.total))
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
                    .uiTestAnchor("triage.card.progress")
            }
        }
    }

    /// "3 of 5" in a sitting; Review has no sitting, so it counts what is waiting.
    private var headerProgress: (position: Int, total: Int)? {
        if isReview { return queue.isEmpty ? nil : (position: handled + 1, total: handled + queue.count) }
        return TriageSession.progress(handled: handled, remaining: queue.count)
    }

    // MARK: Queue

    func advance() {
        if let current { passed.insert(current.id); handled += 1 }
        queue = freshQueue()
        index = min(index, max(queue.count - 1, 0))
        loadSuggestion()
        if queue.isEmpty { index = 0 }
    }

    func freshQueue() -> [KTask] {
        let all = model.store.allTasks()
        if isReview {
            let today = Day.today(calendar: KronosLocale.calendar)
            ReviewSnooze.prune(today: today)
            reviewItems = ReviewQueue.items(in: all, snoozed: ReviewSnooze.table, today: today)
            return reviewItems.map(\.primary).filter { !passed.contains($0.id) }
        }
        let pool = isSweep
            ? SweepQueue.ordered(in: all, now: Date(), calendar: KronosLocale.calendar)
            : TriageQueue.ordered(in: all)
        return pool.filter { !passed.contains($0.id) }
    }

    func reload() {
        passed = []
        queue = freshQueue()
        index = 0
        loadSuggestion()
    }

    /// "Do 5 more": the next sitting over whatever is still in the queue.
    func continueSession() {
        handled = 0
        queue = freshQueue()
        index = 0
        loadSuggestion()
    }
}
