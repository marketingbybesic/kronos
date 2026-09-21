// Kronos/Triage/TriageFlowView.swift
//
// A simple way to triage tasks: go in order through every task missing data, with an
// automated suggestion for each one — as little initiation energy as possible, in service of
// the app's broader ADHD-friendly automation goal. So: ONE task, the suggestion is already
// filled in, Return accepts everything and moves on. No red, no streaks, no pressure copy —
// progress reads as "3 of 12", never a badge (see ui-common.md / art-direction.md).
//
// ROOT CAUSE of a real bug where Return/Tab did nothing live: this view grabbed focus with
// `isFocused = true` SYNCHRONOUSLY inside `.onAppear` (the old line 57). AppShellView keeps
// `TaskListScreen` mounted and focusable underneath every overlay (it is never removed from
// the ZStack, only visually covered — AppShellView.swift:44-53 vs :55-62), so at the instant
// this view appears the list's own `.focusable(true)` row still holds first responder from
// before the overlay opened; a same-tick `isFocused = true` here loses that race and the key
// events keep going to the list, whose own handlers ignore keys they do not recognise (S/M/L,
// 1-4, T/W/N) or run silently underneath (Tab/Return had no meaning there either, so nothing
// visibly happened). A first fix (deferred `DispatchQueue.main.async { isFocused = true }`,
// still below) narrowed the race but did not close it: `.onKeyPress`/`@FocusState` only ever
// deliver a key if THIS view's focusable container is the one SwiftUI resolved to first
// responder, and TaskListScreen's own row is a second focusable, still-mounted candidate a
// tick later too (menu popovers reassign first responder inside AppKit without ever touching
// SwiftUI's FocusState, e.g. every open/close of the priority/effort/deadline/project
// KMenuButton on this same card) — so the follow-up report that the first fix did not hold up
// live was real: any AppKit-level focus change after `.onAppear` re-opens the exact same race
// `.onKeyPress` cannot see. A SECOND root cause: `.onKeyPress` is SwiftUI-focus-gated by
// construction, so no ordering fix inside SwiftUI can make it robust here. Fixed by bypassing
// SwiftUI focus for key dispatch entirely: an `NSEvent.addLocalMonitorForEvents(.keyDown)`
// installed while this view is on screen, the same pattern Kronos/Palette/CommandPaletteView
// .swift's `KeyCatcher` already proves live for the palette overlay in the same ZStack.
import SwiftUI
import KronosCore

/// ONE task at a time from `TriageQueue.ordered`, suggestion pre-filled from
/// `NeighbourTriage.infer` (upgraded by `model.ai?.triage` when it answers), applied through
/// `store.applyTriage(_:to:fillOnly:only:)` — the same call `AutoTriage` uses, so a triage
/// applied here is undoable and marked exactly like an automatic one.
struct TriageFlowView: View {
    let model: AppModel
    let onClose: () -> Void
    /// Snapshot-only seam (default false, every real call site is unaffected): starts the card
    /// with the date field already open, for the `triage.card.date` named screen — the D key
    /// interaction itself cannot be exercised by a static render.
    var startWithDateEditing = false

    // Not `private`: TriageFieldMenus.swift (same target, split out to keep this file under
    // the 500-line lint gate) reads/writes these directly, same as any other member of this
    // struct would — `private` would make that a same-file restriction these two files don't
    // share, `fileprivate` does not cross files either, so plain internal is the correct
    // access level for state that is genuinely still private to this VIEW, just not this file.
    @State var queue: [KTask] = []
    @State var index = 0
    /// Tasks already accepted or skipped in THIS triage session. Without it Tab never left the
    /// card and Return only did when the task ended up with all four fields: the queue was
    /// re-derived from the store and the same task came back first, reading as keys doing
    /// nothing.
    @State private var passed: Set<UUID> = []
    @State var suggestion: TriageResult?
    @State var suggestionSource: SuggestionSource?
    @State var aiEnabled = TriagePrefs.aiSuggestionsEnabled
    @State var isAskingAI = false
    @State var isEditingDate = false
    @State var dateText = ""
    @FocusState var isDateFieldFocused: Bool
    /// CONFIRMED ROOT CAUSE of a real bug where using the keyboard would wipe out a value
    /// just set by hand: a key press (setPriority/setEffort/setDeadline/cycleProject) writes
    /// straight to the store, but `loadSuggestion()` always called
    /// `router.triage(..., lockedFields: [])`, so a same-card AI reply landing after the key
    /// press freely overwrote `suggestion`'s value for the field just chosen —
    /// `TriageFieldMenus.preview*(for:)` reads the STORE value first only when it is non-empty,
    /// so the store write itself was safe, but a field picked via key BEFORE the store write
    /// lands (or a field whose menu is about to be opened) had no such protection, and the
    /// reason line / any later re-vote (`.onChange(of: model.version)` while the AI call was
    /// still in flight) could still show a different value than the one just picked.
    /// `TriageFieldGuard` (Core AI/TriageFieldGuard.swift) exists for exactly this and was
    /// never called from here. Tracks which fields THIS card has had touched (key or menu
    /// pick), cleared on `.onChange(of: current?.id)` below alongside the other per-card
    /// state.
    @State var lockedFields: Set<TriageField> = []
    /// The calm failure line shown under the reason once `askAI` observes either a thrown
    /// error or the router's own silent fallback (`TriageResult.isDeterministic`), so it is
    /// clear when the model isn't answering rather than leaving that silent. `nil` = no
    /// failure to show.
    @State var aiFailure: AIFailureReason?
    /// Seconds since the current AI ask started, driving "Asking <model>… 3s" (brief line 22).
    @State var askingElapsed = 0
    /// Identifies the in-flight ask so a Refresh (or a card/toggle change) makes any EARLIER
    /// reply for this task a no-op instead of racing the newer one onto screen. Not `private`:
    /// TriageAIState.swift (same target, split out to keep this file under the 500-line lint
    /// gate) reads/writes these directly, same as TriageFieldMenus.swift's own state access.
    @State var askID = UUID()
    @State var elapsedTimer: Timer?

    /// Which path produced `suggestion`, shown next to the reason line ("from similar tasks"
    /// vs "AI") so a same-tick neighbour vote can be told apart from a slower model upgrade
    /// that replaced it.
    enum SuggestionSource { case neighbours, ai }
    // AIFailureReason moved to TriageAIState.swift, top-level (file split for the 500-line
    // lint gate) — every reference here is unqualified so the move is source-compatible.

    init(model: AppModel, onClose: @escaping () -> Void, startWithDateEditing: Bool = false) {
        self.model = model
        self.onClose = onClose
        self.startWithDateEditing = startWithDateEditing
    }

    // Not `private`: TriageFieldMenus.swift and TriageAIState.swift (same target, split out to
    // keep this file under the 500-line lint gate) read this directly.
    var current: KTask? { index < queue.count ? queue[index] : nil }

    var body: some View {
        ZStack {
            Tok.bg
            VStack(spacing: Space.x5) {
                header
                if let current {
                    card(for: current)
                } else {
                    KPanel {
                        KEmptyState(icon: "check-square", title: String(localized: "triage.flow.empty"),
                                   actionTitle: String(localized: "triage.flow.hint.close"), onAction: onClose)
                            .frame(maxWidth: .infinity, minHeight: 360)
                    }
                }
            }
            .padding(Space.x6)
            .frame(maxWidth: Metrics.impulsCardWidth)
        }
        // G5 "centriraj": the shell's overlay (AppShellView.swift:57-60) pins this view to the
        // top with `alignment: .top` padding — the same treatment as the palette, which reads
        // fine as a narrow dropdown but leaves a tall triage card sitting high and off-centre.
        // Filling the whole overlay region and centering HERE (maxHeight: .infinity, no
        // alignment override) puts the card in the true middle of the window regardless of
        // what the shell wrapper does above it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .uiTestAnchor("triage.card")
        // ROOT CAUSE #2 fix (see file header): dispatch every key from a local NSEvent monitor,
        // not SwiftUI `.onKeyPress`/`@FocusState` — those only fire while this view itself is
        // AppKit's first responder, a race the list underneath and this card's own menu popovers
        // both keep re-opening. The monitor sees every keyDown while the card is on screen
        // regardless of who AppKit currently thinks owns the field editor.
        .background(TriageKeyCatcher(onKey: handleKey))
        .onAppear {
            reload()
            // Same stale-first-responder hazard as the `isEditingDate` fix below, but for
            // whatever HAD first responder before this card even appeared (e.g. quick add's
            // text field, still focused the instant its own overlay closes and this one opens)
            // — resign it up front so the card's first click on any menu is never eaten.
            if !startWithDateEditing { NSApp.keyWindow?.makeFirstResponder(nil) }
            if startWithDateEditing {
                // Deferred past the SAME tick: `reload()` just took `current` from nil to the
                // first queued task, and `.onChange(of: current?.id)` below reacts to exactly
                // that transition by resetting `isEditingDate = false` (its normal job when a
                // real card-to-card advance should close a stale date field) — opening here
                // synchronously would be immediately undone by that handler.
                DispatchQueue.main.async { openDateField() }
            }
        }
        .onChange(of: model.version) { _, _ in
            // A background triage or an edit elsewhere may have changed what still qualifies —
            // re-derive the queue but keep the current task's place in it if it is still there.
            let keepID = current?.id
            queue = freshQueue()
            index = keepID.flatMap { id in queue.firstIndex { $0.id == id } } ?? min(index, max(queue.count - 1, 0))
            if current == nil { suggestion = nil } else if suggestion == nil { loadSuggestion() }
        }
        .onChange(of: current?.id) { _, _ in
            isEditingDate = false
            lockedFields = []
        }
        // MEASURED ROOT CAUSE of a real bug where a dropdown right after a focus change needed
        // more than one click to work: confirmed with a standalone AppKit repro (deleted after
        // use; same shape kept here) — swapping the date `KTextField` for a `KMenuButton`/`Menu`
        // (any of the three `isEditingDate = false` sites: commit, Esc, card advance) does NOT
        // make AppKit resign the just-hidden field editor's `NSTextView` as the window's first
        // responder, not in the same tick and not on the next run-loop turn either — only an
        // actual mouse-down does that. So the VERY NEXT click anywhere on the card, including
        // on a `Menu`, is first consumed by AppKit's own "resign this stale responder"
        // bookkeeping (the well-known "click 1 resigns, click 2 acts" pattern) and never
        // reaches the Menu's own open handling; a second click, with no more stale responder
        // in the way, works — exactly matching the report. Fix: resign first responder
        // explicitly, synchronously, the moment the date field stops being the logical focus
        // target, so the FIRST click after leaving it is a normal click already.
        .onChange(of: isEditingDate) { _, editing in
            guard !editing else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// One dispatch point for every key the card's hint rows advertise, fed by the NSEvent
    /// monitor below (which already restricted delivery to this card's own key window — see
    /// TriageKeyCatcher's doc comment). `event.charactersIgnoringModifiers` (not `.characters`)
    /// so Shift-driven caps or dead keys never desync a letter shortcut from what the hint row
    /// prints. Returns true when the key was consumed (monitor then swallows it), false to let
    /// it fall through to whatever AppKit would otherwise have done with it (e.g. real typing
    /// in the date field's text editor, or a menu-bar command like Cmd-W).
    private func handleKey(_ event: NSEvent) -> Bool {
        // STACKING GUARD (review fix): triage shares one NSWindow with every other AppShellView
        // overlay (Palette/TimeBlocks/Impuls/Capture — see TriageKeyCatcher's doc comment for
        // the z-order proof), so the window check alone does not tell this card whether it is
        // actually the TOPMOST one on screen. Any overlay that can render above triage
        // (AppShellView.swift's ZStack order: triage=61 < timeBlocks=71 < impuls=80 <
        // capture=89 < palette=98) must own the keyboard instead while it is open; so must the shortcuts card (topmost).
        guard !model.isTimeBlocksOpen, !model.isImpulsOpen, !model.isCaptureOpen, !model.isPaletteOpen, !model.isKeymapOpen else {
            return false
        }
        // MODIFIER GUARD (review fix): Cmd/Ctrl/Opt turn a plain letter into an unrelated menu
        // command (Cmd-W close window, Cmd-Q quit, Cmd-Z undo, Cmd-K palette, …) — none of this
        // card's shortcuts are meant to fire with a modifier held, so any of those three bows
        // out immediately and lets the real command run. Shift alone is fine (e.g. arrives on
        // some layouts for plain digits) and deliberately not checked here.
        let blockingModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: blockingModifiers) else {
            return false
        }
        // TEXT-FIELD GUARD (review fix, brief line 31 "pass events through while a text field
        // is first responder"): belt-and-suspenders alongside the `isEditingDate` state check
        // below — this also covers a future text field on the card this leaf might add later
        // without updating this guard, the same shape TaskListScreen.isTyping already uses.
        let isTypingAnywhereOnCard = (event.window?.firstResponder) is NSTextView
        if isTypingAnywhereOnCard, !isEditingDate {
            // Not the date field (that path has its own three-key allowlist below) and some
            // other text view has the keyboard — only Return/Esc/Tab are ever card-owned while
            // typing, and this card has no other text field today, so let everything through.
            switch event.keyCode {
            case 36, 76, 53, 48: break // Return / keypad Return / Esc / Tab: fall through below.
            default: return false
            }
        }
        if isEditingDate {
            // The date field owns its own characters; only the three card-level keys the brief
            // names apply here, and Return commits the typed date FIRST (KTextField's own
            // `.onSubmit` already does that — `commitTypedDate` is what `.onSubmit` calls —
            // this just gives Return the same effect from the monitor so it is not silently
            // swallowed by SwiftUI's own text-field Return handling racing this monitor).
            switch event.keyCode {
            case 36, 76: // Return / keypad Return
                guard let current else { return false }
                commitTypedDate(for: current)
                return true
            case 53: // Esc
                isEditingDate = false
                return true
            default:
                return false // Tab and every character key stay in the text field.
            }
        }
        switch event.keyCode {
        case 36, 76: acceptAndNext(); return true // Return / keypad Return
        case 48: skip(); return true              // Tab
        case 53: onClose(); return true           // Esc
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": setPriority(.low)
        case "2": setPriority(.medium)
        case "3": setPriority(.high)
        case "4": setPriority(.urgent)
        case "s": setEffort(.s)
        case "m": setEffort(.m)
        case "l": setEffort(.l)
        case "t": setDeadline(.today)
        case "w": setDeadline(.thisWeek)
        case "n": setDeadline(.none)
        case "d": openDateField()
        case "p": cycleProject()
        case "r": retryAI()   // brief line 22: Refresh re-asks at any time, never blocks other keys
        default: return false
        }
        return true
    }

    // MARK: Header — "3 of 12", never a badge, never coloured.

    private var header: some View {
        HStack(spacing: Space.x2) {
            Text(String(localized: "triage.card.title"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            Spacer()
            KToggleRow(String(localized: "triage.flow.aitoggle"), isOn: aiToggleBinding)
                .fixedSize()
                .uiTestAnchor("triage.card.aitoggle")
            if !queue.isEmpty {
                Text(String(format: String(localized: "triage.flow.progress"),
                            min(index, queue.count - 1) + 1, queue.count))
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
    }

    /// A plain `@State` var cannot both drive `KToggleRow`'s `Binding` and persist — this
    /// writes through to `TriagePrefs` (hermetic UserDefaults, same shape as
    /// `AppearancePrefs`) on every flip and re-derives the current card's suggestion so
    /// toggling off immediately drops any AI-upgraded value back to the neighbour vote.
    private var aiToggleBinding: Binding<Bool> {
        Binding(
            get: { aiEnabled },
            set: { newValue in
                aiEnabled = newValue
                TriagePrefs.aiSuggestionsEnabled = newValue
                loadSuggestion()
            }
        )
    }

    // MARK: Card — big title, prefilled suggestion, one-line reason, key hints.

    private func card(for task: KTask) -> some View {
        KPanel {
            VStack(alignment: .leading, spacing: Space.x5) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(task.title)
                        .font(Typo.hero)
                        .foregroundStyle(Tok.textPrimary)
                        .lineLimit(3)
                    if let projectName = task.project?.name {
                        Text(projectName)
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                    }
                }

                if let reason = suggestion?.reason {
                    HStack(spacing: Space.x2) {
                        Text(localizedNeighbourReason(reason, isNeighbourSourced: suggestionSource != .ai))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textSecondary)
                        if let suggestionSource {
                            Text(suggestionSource == .ai ? String(localized: "triage.flow.source.ai")
                                                          : String(localized: "triage.flow.source.neighbours"))
                                .font(Typo.meta)
                                .foregroundStyle(Tok.textTertiary)
                        }
                        Spacer(minLength: 0)
                        aiStateRow
                    }
                }

                if suggestion?.reason == nil { HStack { Spacer(minLength: 0); aiStateRow } }

                VStack(spacing: 0) {
                    KPropertyRow(String(localized: "viewoptions.field.priority")) {
                        priorityMenu(for: task)
                    }
                    KHairline()
                    KPropertyRow(String(localized: "viewoptions.field.effort")) {
                        effortMenu(for: task)
                    }
                    KHairline()
                    KPropertyRow(String(localized: "viewoptions.field.deadline")) {
                        deadlineRow(for: task)
                    }
                    KHairline()
                    KPropertyRow(String(localized: "viewoptions.field.project")) {
                        projectMenu(for: task)
                    }
                }
                .frame(minHeight: Metrics.controlRegular * 5)   // G5 "povecaj visinu": room for the date field opening inline

                keyHints
            }
            .frame(minHeight: 420)   // G5: taller than the old card, still one screen, no scroll
        }
        .id(task.id)   // fresh @State-free identity per card so hover/menu state resets
    }

    // aiStateRow moved to TriageAIState.swift (file split for the 500-line lint gate).

    // Two rows: the field hints (what each key sets) on top, the flow hints (accept/skip/
    // close) on the bottom. Each hint is a flow item (cap(s) + label) that moves to the
    // next line as one piece when the card is too narrow for the whole row — a plain
    // HStack let SwiftUI compress a multi-alternative cap's text instead (wrapped mid-word).
    private var keyHints: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            KKeyHintRow(fieldHints)
            KKeyHintRow(flowHints)
        }
    }

    private var fieldHints: [(keys: [String], label: String)] {
        var items: [(keys: [String], label: String)] = [
            (["1", "–", "4"], String(localized: "viewoptions.field.priority")),
            (["S", "M", "L"], String(localized: "viewoptions.field.effort")),
            (["T", "W", "N"], String(localized: "viewoptions.field.deadline")),
            (["D"], String(localized: "triage.flow.date.typeit")),
            (["P"], String(localized: "viewoptions.field.project")),
        ]
        if aiEnabled, model.ai != nil {
            items.append((["R"], String(localized: "triage.flow.ai.refresh")))
        }
        return items
    }

    private var flowHints: [(keys: [String], label: String)] {
        [
            (["⏎"], String(localized: "triage.flow.hint.accept")),
            (["⇥"], String(localized: "triage.flow.hint.skip")),
            (["⎋"], String(localized: "triage.flow.hint.close")),
        ]
    }

    // MARK: Actions

    enum QuickDeadline { case today, tomorrow, thisWeek, none }

    private func setPriority(_ p: KPriority) {
        guard let current else { return }
        lockedFields.insert(.priority)
        model.store.setPriority(current.id, p)
        model.didMutate()
    }
    private func setEffort(_ e: KEffort) {
        guard let current else { return }
        lockedFields.insert(.effort)
        model.store.setEffort(current.id, e)
        model.didMutate()
    }
    /// "P" cycles through projects (none -> each project in list order -> none). A native
    /// SwiftUI `Menu` (what the row's own picker uses) has no programmatic-open binding, so a
    /// key cannot pop it open; this gives P a real, testable keyboard action instead of a
    /// silent no-op. The row's own menu still opens normally on click for a direct pick.
    private func cycleProject() {
        guard let current else { return }
        let projects = model.store.allProjects()
        guard !projects.isEmpty else { return }
        lockedFields.insert(.project)
        let currentIndex = current.project.flatMap { p in projects.firstIndex { $0.id == p.id } }
        let next = currentIndex.map { $0 + 1 } ?? 0
        let project = next < projects.count ? projects[next] : nil
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

    /// Return: apply the whole prefilled suggestion (fill-only — never overwrites a field
    /// already touched this card, in the store or with a key press above) in one undo step,
    /// then advance. This is the "press Return a few times" path this flow is built around.
    private func acceptAndNext() {
        guard let current else { onClose(); return }
        if let suggestion {
            model.store.applyTriage(suggestion, to: current.id, fillOnly: true)
        } else {
            model.store.update(current.id) { $0.needsTriage = false }
        }
        model.didMutate()
        advance()
    }

    private func skip() { advance() }

    private func advance() {
        if let current { passed.insert(current.id) }
        queue = freshQueue()
        index = min(index, max(queue.count - 1, 0))
        loadSuggestion()
        if queue.isEmpty { index = 0 }
    }

    private func freshQueue() -> [KTask] {
        TriageQueue.ordered(in: model.store.allTasks()).filter { !passed.contains($0.id) }
    }

    private func reload() {
        passed = []
        queue = freshQueue()
        index = 0
        loadSuggestion()
    }

    // loadSuggestion / retryAI / askAI / neighbours moved to TriageAIState.swift (file split
    // for the 500-line lint gate, same reason TriageFieldMenus.swift was split out).
}

