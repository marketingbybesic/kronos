// Kronos/Welcome/TourOverlay.swift — the live side of the guided tour (TourSteps.swift holds
// the rules). Parts of the window mark themselves with `.tourAnchor(_:)`; AppShellView lays
// `TourOverlay` over everything and reads those anchors. The overlay dims the window except a
// cut-out around the current part (which stays clickable, so the user can try it right away)
// and shows one bubble: step counter, title, one or two lines, Skip / Back / Next.
// Pure #000 bubble with a hairline border, like every other floating surface.
import SwiftUI
import AppKit
import KronosCore

struct TourBubbleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

extension View {
    /// Marks this view as the part of the window a tour step can point at.
    func tourAnchor(_ anchor: TourAnchor, when active: Bool = true) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { active ? [anchor: $0] : [:] }
    }
}

@Observable
@MainActor
final class TourCenter {
    static let shared = TourCenter()
    private(set) var index: Int?
    private(set) var direction = 1
    private weak var model: AppModel?
    /// The sample task this run made (empty store only); removed when the tour ends, however it ends.
    private(set) var sampleTaskIDs: [UUID] = []

    var isRunning: Bool { index != nil }
    var step: TourStep? { index.map { TourSteps.all[$0] } }

    /// `sample`: nil decides by the store (a sample only where no open task exists); a test can force it.
    func start(model: AppModel, sample: Bool? = nil) {
        self.model = model
        removeOrphanSample(model: model)
        direction = 1
        let wantSample = sample ?? OnboardingLogic.sampleTaskNeeded(
            openTaskCount: model.store.allTasks().filter { $0.status != .done }.count)
        if wantSample, sampleTaskIDs.isEmpty { createSample(model: model) }
        index = 0
        prepare()
        scheduleCheck()
        reselectSampleSoon()
        NSApp.activate(ignoringOtherApps: true)
    }

    func next() { move(1) }
    func back() { move(-1) }
    func end() {
        index = nil
        pendingCheck?.cancel()
        removeSample()
    }

    // MARK: Sample task

    /// An empty store leaves the tour pointing at nothing (half the steps would be skipped), so
    /// the tour brings one task of its own. NoUndo: it is not the user's action and must never
    /// become their "last thing to undo". Auto-triage is switched off for it (no AI call).
    private func createSample(model: AppModel) {
        let store = model.store
        for key in TourSample.titleKeys {
            let task = store.createNoUndo(title: String(localized: String.LocalizationValue(key)))
            store.updateNoUndo(task.id) { $0.needsTriage = false }
            sampleTaskIDs.append(task.id)
        }
        KronosEnv.defaults.set(sampleTaskIDs.map(\.uuidString).joined(separator: ","), forKey: TourSample.defaultsKey)
        // Selected from the start, so the inspector step has its part on screen and the tour shows
        // its full length (every step) from the first bubble.
        model.selectedTaskID = sampleTaskIDs.first
        // The sample sits in the Inbox and in All: be on one of them so the first row is it.
        if model.scope != .inbox, model.scope != .all { model.scope = .inbox; model.persist() }
        model.didMutate()
    }

    /// The list drops a selection made before it has laid out the new rows, so the selection is
    /// made once more a moment later when nothing is selected.
    private func reselectSampleSoon() {
        guard !sampleTaskIDs.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, let model = self.model, model.selectedTaskID == nil else { return }
                model.selectedTaskID = self.sampleTaskIDs.first
            }
        }
    }

    /// Soft-deletes the sample without an undo step and forgets it.
    private func removeSample() {
        let ids = sampleTaskIDs
        sampleTaskIDs = []
        KronosEnv.defaults.removeObject(forKey: TourSample.defaultsKey)
        guard let model, !ids.isEmpty else { return }
        delete(ids, model: model)
    }

    private func delete(_ ids: [UUID], model: AppModel) {
        var removed = false
        for id in ids where model.store.task(id) != nil {
            model.store.softDeleteNoUndo(id)
            if model.selectedTaskID == id { model.selectedTaskID = nil }
            removed = true
        }
        if removed { model.didMutate() }
    }

    /// A sample left behind by an app quit in the middle of a tour (its id is still stored).
    func removeOrphanSample(model: AppModel) {
        guard !isRunning, let raw = KronosEnv.defaults.string(forKey: TourSample.defaultsKey) else { return }
        KronosEnv.defaults.removeObject(forKey: TourSample.defaultsKey)
        delete(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }, model: model)
    }

    /// Reaching Done (not Skip): the same cue as finishing a task, so the tour ends on a reward.
    func finish() { KronosSounds.play(.task); end() }

    /// The parts on screen at the last look (the overlay reports them), for the live test.
    private(set) var latestAvailable: Set<TourAnchor> = []
    private var pendingCheck: DispatchWorkItem?

    /// Called by the overlay on every change of what is on screen; only remembers it.
    func noteAvailable(_ available: Set<TourAnchor>) {
        latestAvailable = available
    }

    /// A step is judged only after the user moved (or the tour started) and the window had a
    /// moment to settle: the Now card and a freshly selected task report their anchors a few
    /// frames later, and judging on the first frame skipped steps whose part was about to show.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcile(available: self.latestAvailable)
            }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Moves on (in the direction of travel) when the current step's part is missing, ends the
    /// tour when nothing is left.
    private var missedOnce = false

    func reconcile(available: Set<TourAnchor>) {
        guard let i = index, !TourLogic.isAvailable(TourSteps.all[i].anchor, available) else { missedOnce = false; return }
        // A part can vanish for a frame while the list re-lays out (the Learn card appearing
        // right after "Show me around" made steps 2-5 skip): only skip when it is missing in two
        // samples half a second apart.
        guard missedOnce else { missedOnce = true; scheduleCheck(); return }
        missedOnce = false
        if let j = TourLogic.resolve(from: i, direction: direction, steps: TourSteps.all, available: available)
            ?? TourLogic.resolve(from: i, direction: -direction, steps: TourSteps.all, available: available) {
            index = j
            prepare()
            scheduleCheck()
        } else {
            end()
        }
    }

    private func move(_ d: Int) {
        guard let i = index else { return }
        direction = d
        let target = i + d
        if target >= TourSteps.all.count { finish(); return }
        guard target >= 0 else { return }
        index = target   // the check below skips it if its part is not on screen
        missedOnce = false
        prepare()
        scheduleCheck()
    }

    private func prepare() {
        guard let step, let model else { return }
        switch step.prepare {
        case .none: break
        case .selectFirstTask:
            if model.selectedTaskID == nil, let id = model.focusTaskID { model.selectedTaskID = id }
        }
    }

    /// Snapshot fixtures only. `model`: also run the real start path (sample task, first step's
    /// preparation) so a shot shows what a first-run user sees.
    func setFixture(index: Int?, model: AppModel? = nil, sample: Bool = false) {
        if let model {
            self.model = model
            if sample, sampleTaskIDs.isEmpty { createSample(model: model) }
        }
        self.index = index
        direction = 1
        if model != nil { prepare(); reselectSampleSoon() }
    }
}

struct TourOverlay: View {
    let anchors: [TourAnchor: Anchor<CGRect>]
    var center = TourCenter.shared
    @Environment(\.kAccent) private var accent
    /// Drives the accent ring's slow breath around the highlighted part (off under Reduce Motion).
    @State private var breathing = false
    /// The bubble's real height (it grows with text size and Croatian copy); placement uses it.
    @State private var bubbleHeight: CGFloat = 190
    /// Keyboard focus on the bubble's primary button, so Space and Return act on the step at once.
    @FocusState private var nextFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            if let index = center.index {
                let step = TourSteps.all[index]
                // A part that renders nothing (a hidden card) still reports a zero-size anchor.
                let available = Set(anchors.filter { proxy[$0.value].width > 1 && proxy[$0.value].height > 1 }.keys)
                let rect = available.contains(step.anchor) ? anchors[step.anchor].map { proxy[$0] } : nil
                // The cards the bubble must not hide while it talks about something else.
                let avoid: [CGRect] = [TourAnchor.learnCard, .nowCard]
                    .filter { $0 != step.anchor && available.contains($0) }
                    .compactMap { anchors[$0].map { proxy[$0] } }
                ZStack(alignment: .topLeading) {
                    dim(cutout: rect, in: proxy.size)
                    // While a part is still appearing, show no bubble rather than one parked in
                    // the corner that jumps a frame later (only the menu bar step has no part).
                    if rect != nil || step.anchor == .menuBar {
                        bubble(step, index: index, available: available)
                            .frame(width: Self.bubbleWidth)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { box in
                                Color.clear.preference(key: TourBubbleHeightKey.self, value: box.size.height)
                            })
                            .offset(Self.bubbleOffset(for: rect, avoid: avoid, bubbleHeight: bubbleHeight, in: proxy.size))
                    }
                }
                .onPreferenceChange(TourBubbleHeightKey.self) { if $0 > 1 { bubbleHeight = $0 } }
                .animation(Motion.reduceMotion ? nil : Motion.curve(Motion.tour), value: rect)
                .onAppear {
                    center.noteAvailable(available)
                    speak(step: step, index: index, available: available)
                    if !Motion.reduceMotion {
                        withAnimation(.easeInOut(duration: Motion.breathLoop).repeatForever(autoreverses: true)) { breathing = true }
                    }
                }
                .onChange(of: index) { _, now in
                    center.noteAvailable(available)
                    speak(step: TourSteps.all[now], index: now, available: available)
                }
                .onChange(of: available) { _, now in center.noteAvailable(now) }
                .transition(.opacity)
            }
        }
        .animation(Motion.curve(Motion.fast), value: center.index)
    }

    static let bubbleWidth: CGFloat = 340
    private static let bubbleGap: CGFloat = Space.x3

    /// See `TourPlacement.origin`: beside a narrow part, below or above a wide one, clear of the
    /// cards, inside the window; the menu bar step (no part) goes to a free corner.
    static func bubbleOffset(for rect: CGRect?, avoid: [CGRect], bubbleHeight: CGFloat, in size: CGSize) -> CGSize {
        let p = TourPlacement.origin(target: rect, avoid: avoid, in: size,
                                     bubble: CGSize(width: bubbleWidth, height: bubbleHeight),
                                     margin: Space.x4, gap: bubbleGap)
        return CGSize(width: p.x, height: p.y)
    }

    /// Everything dimmed except the current part; the cut-out passes clicks through.
    private func dim(cutout: CGRect?, in size: CGSize) -> some View {
        let hole = cutout?.insetBy(dx: -Space.x2, dy: -Space.x2)
        var path = Path(CGRect(origin: .zero, size: size))
        if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: Radius.card, height: Radius.card)) }
        return ZStack {
            path.fill(Tok.scrim, style: FillStyle(eoFill: true))
            if let hole {
                // On #000 a dimmer alone reads as "nothing happened" (user feedback: boring), so
                // the highlighted part wears the accent: a soft glow plus a ring that breathes.
                let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                shape
                    .strokeBorder(accent.opacity(breathing ? 0.55 : 0.25), lineWidth: Space.x2)
                    .blur(radius: Space.x3)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
                shape
                    .strokeBorder(accent.opacity(breathing ? 1 : 0.6), lineWidth: Metrics.strokeQuiet)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(path, eoFill: true)
        .onTapGesture { }   // swallow clicks on the dimmed area; the cut-out stays live
    }

    private var skipButton: some View {
        Button(String(localized: "welcome.tour.skip")) { center.end() }
            .kButton(.ghost, size: .compact)
            .keyboardShortcut(.cancelAction)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func forwardButtons(step: TourStep, progress: (current: Int, total: Int), isLast: Bool) -> some View {
        if step.anchor == .menuBar {
            Button(String(localized: "welcome.tour.showit")) {
                NotificationCenter.default.post(name: .kronosShowOrdoRequested, object: nil)
            }
            .kButton(.secondary, size: .compact)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        if progress.current > 1 {
            Button(String(localized: "welcome.tour.back")) { center.back() }
                .kButton(.ghost, size: .compact)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        Button(String(localized: isLast ? "welcome.tour.done" : "welcome.tour.next")) {
            center.next()
        }
        .kButton(.primary, size: .compact)
        .keyboardShortcut(.defaultAction)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .focused($nextFocused)
        .uiTestAnchor("tour.next")
    }

    /// Says the step aloud and puts keyboard focus on the bubble's primary button. Focus is set on the
    /// next turn: the bubble is rebuilt for every step (`.id(index)`), so a same-tick request would
    /// land on the view that is about to go away.
    private func speak(step: TourStep, index: Int, available: Set<TourAnchor>) {
        let progress = TourLogic.progress(index: index, steps: TourSteps.all, available: available)
        TourAnnouncer.announce(
            position: String(format: String(localized: "welcome.tour.progress"), progress.current, progress.total),
            title: String(localized: String.LocalizationValue(step.titleKey)),
            body: String(localized: String.LocalizationValue(step.bodyKey)))
        DispatchQueue.main.async { nextFocused = true }
    }

    private func bubble(_ step: TourStep, index: Int, available: Set<TourAnchor>) -> some View {
        let progress = TourLogic.progress(index: index, steps: TourSteps.all, available: available)
        let isLast = TourLogic.resolve(from: index, direction: 1, steps: TourSteps.all, available: available) == nil
        let keys = step.hotkeyID.flatMap { HotkeyRegistry.current(for: $0)?.displayKeys } ?? []
        return VStack(alignment: .leading, spacing: Space.x3) {
            HStack(spacing: Space.x1) {
                ForEach(0..<progress.total, id: \.self) { i in
                    Capsule()
                        .fill(i < progress.current ? accent : Tok.glyphEmpty)
                        .frame(width: i == progress.current - 1 ? 18 : 6, height: 6)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: String(localized: "welcome.tour.progress"), progress.current, progress.total))
            .animation(Motion.curve(Motion.medium), value: progress.current)
            Text(String(localized: String.LocalizationValue(step.titleKey)))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: String.LocalizationValue(step.bodyKey)))
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !keys.isEmpty { KKeyHintItem(keys, label: "") }
            // One row when every button fits at its natural width; otherwise Skip drops below, so a
            // long Croatian label at text size L is never cut ("Preskoči" lost its last letters).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.x2) {
                    skipButton
                    Spacer(minLength: Space.x2)
                    forwardButtons(step: step, progress: progress, isLast: isLast)
                }
                VStack(alignment: .leading, spacing: Space.x2) {
                    HStack(spacing: Space.x2) {
                        Spacer(minLength: 0)
                        forwardButtons(step: step, progress: progress, isLast: isLast)
                    }
                    skipButton
                }
            }
        }
        // The bubble is one group for VoiceOver, named by the step, so moving into it reads the title
        // first; the keyboard focus sits on its primary button (`nextFocused`).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: String.LocalizationValue(step.titleKey)))
        .padding(Space.x4)
        .background(Tok.overlay)
        .kBorder(Tok.borderStrong, radius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: accent.opacity(0.18), radius: 24, y: 8)
        .id(index)   // fresh subtree per step so the transition below reads as a page turn
        .transition(Motion.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
    }
}
