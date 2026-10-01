// Kronos/Welcome/TourOverlay.swift — the live side of the guided tour (TourSteps.swift holds
// the rules). Parts of the window mark themselves with `.tourAnchor(_:)`; AppShellView lays
// `TourOverlay` over everything and reads those anchors. The overlay dims the window except a
// cut-out around the current part (which stays clickable, so the user can try it right away)
// and shows one bubble: step counter, title, one or two lines, Skip / Back / Next.
// Pure #000 bubble with a hairline border, like every other floating surface.
import SwiftUI
import AppKit
import KronosCore

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

    var isRunning: Bool { index != nil }
    var step: TourStep? { index.map { TourSteps.all[$0] } }

    func start(model: AppModel) {
        self.model = model
        direction = 1
        index = 0
        prepare()
        scheduleCheck()
        NSApp.activate(ignoringOtherApps: true)
    }

    func next() { move(1) }
    func back() { move(-1) }
    func end() { index = nil; pendingCheck?.cancel() }

    /// Reaching Done (not Skip): the same cue as finishing a task, so the tour ends on a reward.
    func finish() { KronosSounds.play(.task); end() }

    private var latestAvailable: Set<TourAnchor> = []
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
            index = nil
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

    /// Snapshot fixtures only.
    func setFixture(index: Int?) { self.index = index; direction = 1 }
}

struct TourOverlay: View {
    let anchors: [TourAnchor: Anchor<CGRect>]
    var center = TourCenter.shared
    @Environment(\.kAccent) private var accent
    /// Drives the accent ring's slow breath around the highlighted part (off under Reduce Motion).
    @State private var breathing = false

    var body: some View {
        GeometryReader { proxy in
            if let index = center.index {
                let step = TourSteps.all[index]
                // A part that renders nothing (a hidden card) still reports a zero-size anchor.
                let available = Set(anchors.filter { proxy[$0.value].width > 1 && proxy[$0.value].height > 1 }.keys)
                let rect = available.contains(step.anchor) ? anchors[step.anchor].map { proxy[$0] } : nil
                ZStack(alignment: .topLeading) {
                    dim(cutout: rect, in: proxy.size)
                    // While a part is still appearing, show no bubble rather than one parked in
                    // the corner that jumps a frame later (only the menu bar step has no part).
                    if rect != nil || step.anchor == .menuBar {
                        bubble(step, index: index, available: available)
                            .frame(width: Self.bubbleWidth)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(Self.bubbleOrigin(for: rect, in: proxy.size))
                    }
                }
                .animation(Motion.reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.32), value: rect)
                .onAppear {
                    center.noteAvailable(available)
                    if !Motion.reduceMotion {
                        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathing = true }
                    }
                }
                .onChange(of: index) { _, _ in center.noteAvailable(available) }
                .onChange(of: available) { _, now in center.noteAvailable(now) }
                .transition(.opacity)
            }
        }
        .animation(Motion.curve(Motion.fast), value: center.index)
    }

    static let bubbleWidth: CGFloat = 340
    private static let bubbleGap: CGFloat = Space.x3
    private static let estimatedBubbleHeight: CGFloat = 190

    /// Beside a narrow part (the sidebar, the inspector column: under a third of the window),
    /// so the bubble never covers what it talks about; below a wide part when there is room,
    /// else above. Clamped inside the window. No part (menu bar step): top-trailing corner.
    static func bubbleOrigin(for rect: CGRect?, in size: CGSize) -> CGSize {
        let margin = Space.x4
        guard let rect else { return CGSize(width: size.width - bubbleWidth - margin, height: margin) }
        var x: CGFloat
        var y: CGFloat
        if rect.width < size.width / 3 || rect.height > size.height / 2 {
            let rightSide = rect.maxX + bubbleGap + bubbleWidth <= size.width - margin
            x = rightSide ? rect.maxX + bubbleGap : rect.minX - bubbleGap - bubbleWidth
            y = rect.minY + margin
        } else {
            x = rect.minX
            y = rect.maxY + bubbleGap + estimatedBubbleHeight <= size.height - margin
                ? rect.maxY + bubbleGap : rect.minY - bubbleGap - estimatedBubbleHeight
        }
        x = min(max(x, margin), size.width - bubbleWidth - margin)
        y = min(max(y, margin), size.height - estimatedBubbleHeight - margin)
        return CGSize(width: x, height: y)
    }

    /// Everything dimmed except the current part; the cut-out passes clicks through.
    private func dim(cutout: CGRect?, in size: CGSize) -> some View {
        let hole = cutout?.insetBy(dx: -Space.x2, dy: -Space.x2)
        var path = Path(CGRect(origin: .zero, size: size))
        if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: Radius.card, height: Radius.card)) }
        return ZStack {
            path.fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
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
            HStack(spacing: Space.x2) {
                Button(String(localized: "welcome.tour.skip")) { center.end() }
                    .kButton(.ghost, size: .compact)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Space.x2)
                if step.anchor == .menuBar {
                    Button(String(localized: "welcome.tour.showit")) {
                        NotificationCenter.default.post(name: .kronosShowOrdoRequested, object: nil)
                    }
                    .kButton(.secondary, size: .compact)
                }
                if progress.current > 1 {
                    Button(String(localized: "welcome.tour.back")) { center.back() }
                        .kButton(.ghost, size: .compact)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(String(localized: isLast ? "welcome.tour.done" : "welcome.tour.next")) {
                    center.next()
                }
                .kButton(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)
                .uiTestAnchor("tour.next")
            }
        }
        .padding(Space.x4)
        .background(Tok.overlay)
        .kBorder(Tok.borderStrong, radius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: accent.opacity(0.18), radius: 24, y: 8)
        .id(index)   // fresh subtree per step so the transition below reads as a page turn
        .transition(Motion.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
    }
}
