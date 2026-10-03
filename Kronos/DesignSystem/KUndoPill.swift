// Kronos/DesignSystem/KUndoPill.swift
// 5-second undo affordance: a check inside a countdown ring drawn in the accent, the message,
// an optional primary action (for example "Start" the next task, answered by Return) and Undo.
// The window is `Motion.undoWindow` so every undo affordance in the app shares one timing
// constant. Reduce Motion: the ring stays a static full circle instead of draining, but the
// timer itself still expires at 5 s (⌘Z always works whether or not the pill is visible).
import SwiftUI

/// Shell-level undo affordance any screen can raise: completing/deleting from the Now card,
/// the inspector, triage, Impuls or the menu bar must all raise the same pill, not just the
/// list. A plain `@Observable` singleton rather than an `AppModel` property: `AppModel`/
/// `UIContract.swift` is a frozen contract file, so a shared property there would be an edit
/// outside this component's boundary. Every call site posts `UndoToastCenter.shared.show(message:)`; the
/// shell mounts ONE `KUndoPill` bound to `UndoToastCenter.shared.current` (see the overlay in
/// `AppShellView`). The list keeps its own local flow working unchanged — `ListCompletion`
/// and the row/list delete paths now post here instead of a per-screen `@State` — so the
/// pill is identical wherever the mutation happened.
@MainActor
@Observable
public final class UndoToastCenter {
    public static let shared = UndoToastCenter()
    public private(set) var current: ListUndoState?
    private init() {}

    /// `customUndo` is for a change that is NOT in the store's undo stack (pinning the focus
    /// task): the pill's Undo button and `performCustomUndo()` run it instead of `store.undo()`.
    /// `primaryTitle` + `onPrimary` add one forward action to the pill (completion hands off to
    /// the next task: "Start"); the screen's Return handler calls `performPrimary()`.
    public func show(_ message: String, customUndo: (() -> Void)? = nil,
                     primaryTitle: String? = nil, onPrimary: (() -> Void)? = nil) {
        current = ListUndoState(message: message, customUndo: customUndo,
                                primaryTitle: primaryTitle, onPrimary: onPrimary)
    }

    /// A message with nothing to undo (a refused action): the same pill, without the Undo button,
    /// so Cmd-Z hints never promise to reverse something that did not happen.
    public func showNotice(_ message: String) {
        current = ListUndoState(message: message, isNotice: true)
    }

    /// Runs and clears the on-screen toast's own undo, if it has one. Returns false when the
    /// toast is a store change (the caller then uses `store.undo()` as before).
    @discardableResult
    public func performCustomUndo() -> Bool {
        guard let undo = current?.customUndo else { return false }
        current = nil
        undo()
        return true
    }

    /// Runs and clears the on-screen toast's primary action, if it has one. Returns false when
    /// there is none, so a Return handler can fall through to its normal meaning.
    @discardableResult
    public func performPrimary() -> Bool {
        guard let primary = current?.onPrimary else { return false }
        current = nil
        primary()
        return true
    }

    /// Only clears if the toast on screen is still the one that expired — a fresh toast
    /// raised while the old one's timer was in flight must not be dismissed by it.
    public func expire(_ id: UUID) {
        if current?.id == id { current = nil }
    }

    public func dismiss() {
        current = nil
    }
}

/// One completed/deleted/uncompleted action's undo message. `Identifiable` so a fresh toast
/// (a new `id`) always replaces an in-flight one rather than being mistaken for the same one.
public struct ListUndoState: Identifiable, Equatable {
    public let id = UUID()
    public let message: String
    public let customUndo: (() -> Void)?
    /// True for a plain message (no Undo button, no check: nothing was done).
    public let isNotice: Bool
    /// Optional forward action shown before Undo ("Start"), run by `performPrimary()`.
    public let primaryTitle: String?
    public let onPrimary: (() -> Void)?
    public init(message: String, customUndo: (() -> Void)? = nil, isNotice: Bool = false,
                primaryTitle: String? = nil, onPrimary: (() -> Void)? = nil) {
        self.message = message
        self.customUndo = customUndo
        self.isNotice = isNotice
        self.primaryTitle = onPrimary == nil ? nil : primaryTitle
        self.onPrimary = primaryTitle == nil ? nil : onPrimary
    }
    public static func == (a: ListUndoState, b: ListUndoState) -> Bool { a.id == b.id }
}

/// The undo window's clock: how much of it is left, and whether it is paused. Pure value, so a
/// hand table can drive it with fixed instants.
struct UndoPillCountdown: Equatable {
    let duration: Double
    /// Seconds left as of `runningSince` (or for good, while paused).
    private(set) var left: Double
    /// When the clock last started running; nil while paused.
    private(set) var runningSince: Date?

    init(duration: Double) {
        self.duration = duration
        self.left = duration
    }

    var isPaused: Bool { runningSince == nil }

    func remaining(at now: Date) -> Double {
        guard let since = runningSince else { return left }
        return max(0, left - now.timeIntervalSince(since))
    }

    /// Share of the window still left, 1 -> 0 (the ring's trim).
    func fraction(at now: Date) -> Double {
        duration > 0 ? remaining(at: now) / duration : 0
    }

    mutating func pause(at now: Date) {
        guard runningSince != nil else { return }
        left = remaining(at: now)
        runningSince = nil
    }

    mutating func resume(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }
}

public struct KUndoPill: View {
    let message: String
    let onUndo: () -> Void
    let onExpire: () -> Void
    var duration: Double
    var showsUndo: Bool
    var primaryTitle: String?
    var onPrimary: (() -> Void)?
    @State private var progress: Double = 1.0   // 1 -> 0 over `duration`
    /// The time left, paused while the pointer rests on the pill or VoiceOver is on it: someone
    /// reading it, or about to press Undo, must not lose it under their hand.
    @State private var countdown: UndoPillCountdown?
    @State private var expiry: DispatchWorkItem?
    @State private var isHovering = false
    @AccessibilityFocusState private var isVoiceOverFocused: Bool
    @Environment(\.kAccent) private var accent

    /// `showsUndo` false = a notice: no Undo button and no check. `primaryTitle` + `onPrimary`
    /// (both or neither) add the forward action, with a Return key cap.
    public init(message: String, duration: Double = Motion.undoWindow, showsUndo: Bool = true,
                primaryTitle: String? = nil, onPrimary: (() -> Void)? = nil,
                onUndo: @escaping () -> Void, onExpire: @escaping () -> Void) {
        self.message = message
        self.duration = duration
        self.showsUndo = showsUndo
        self.primaryTitle = onPrimary == nil ? nil : primaryTitle
        self.onPrimary = primaryTitle == nil ? nil : onPrimary
        self.onUndo = onUndo
        self.onExpire = onExpire
    }

    /// The shell's pill, built from the center's state (message, notice, primary action).
    public init(state: ListUndoState, duration: Double = Motion.undoWindow,
                onUndo: @escaping () -> Void, onExpire: @escaping () -> Void) {
        self.init(message: state.message, duration: duration, showsUndo: !state.isNotice,
                  primaryTitle: state.primaryTitle, onPrimary: state.onPrimary,
                  onUndo: onUndo, onExpire: onExpire)
    }

    public var body: some View {
        HStack(spacing: Space.x2) {
            timer
            Text(message)
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(1)
            if let primaryTitle, let onPrimary {
                Button {
                    if !UndoToastCenter.shared.performPrimary() { onPrimary() }
                } label: {
                    HStack(spacing: Space.x1) {
                        Text(primaryTitle)
                            .font(Typo.metaStrong)
                            .foregroundStyle(Tok.textPrimary)
                            .lineLimit(1)
                        KKeyHint("⏎")
                    }
                    .frame(minHeight: Metrics.minHit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // The key hint teaches that Cmd-Z does the same thing (audit D11).
            if showsUndo {
                Button {
                    if !UndoToastCenter.shared.performCustomUndo() { onUndo() }
                } label: {
                    HStack(spacing: Space.x1) {
                        Text(String(localized: "undo.action"))
                            .font(Typo.metaStrong)
                            .foregroundStyle(Tok.textPrimary)
                        KKeyHint("⌘", "Z")
                    }
                    .frame(minHeight: Metrics.minHit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.x3)
        .frame(height: Metrics.undoPillHeight)
        .frame(maxWidth: Metrics.undoPillMaxWidth)   // a long title truncates inside the pill instead of widening it
        .background(Tok.overlay)
        .kBorder(Tok.borderControl, radius: Radius.full)
        .clipShape(RoundedRectangle(cornerRadius: Radius.full, style: .continuous))
        .onHover { isHovering = $0 }
        .onAppear {
            countdown = UndoPillCountdown(duration: duration)
            run(held: false)
            #if !RELEASE
            Self.liveHold = { held in run(held: held) }
            #endif
        }
        .onDisappear { expiry?.cancel() }
        .onChange(of: isHovering) { _, _ in run(held: isHeld) }
        .onChange(of: isVoiceOverFocused) { _, _ in run(held: isHeld) }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($isVoiceOverFocused)
    }

    private var isHeld: Bool { isHovering || isVoiceOverFocused }

    /// Pauses (`held`) or runs the countdown: the ring stops where it is and the expiry waits;
    /// running again drains what was left and expires when it is gone.
    private func run(held: Bool) {
        guard var clock = countdown else { return }
        let now = Date()
        expiry?.cancel()
        expiry = nil
        if held {
            clock.pause(at: now)
            countdown = clock
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { progress = clock.fraction(at: now) }
            return
        }
        clock.resume(at: now)
        countdown = clock
        let left = clock.remaining(at: now)
        // A snapshot renders the pill's resting state, so it is the same with and without
        // Reduce Motion; the live app drains the ring.
        if !Motion.reduceMotion && !Self.isSnapshot {
            withAnimation(.linear(duration: left)) { progress = 0 }
        }
        let work = DispatchWorkItem { onExpire() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: work)
    }

    #if !RELEASE
    /// Live-test seam: holds or releases the pill on screen exactly as hovering it does.
    static var liveHold: ((Bool) -> Void)?
    #endif

    /// Countdown ring in the accent around a check (the action is done); a notice keeps the
    /// ring only, since nothing was done.
    private var timer: some View {
        ZStack {
            Circle().stroke(Tok.hairline, lineWidth: Metrics.undoPillTimerStroke)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: Metrics.undoPillTimerStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsUndo {
                CheckMark()
                    .stroke(Tok.textPrimary, style: StrokeStyle(lineWidth: Metrics.undoPillTimerStroke * 0.75,
                                                                lineCap: .round, lineJoin: .round))
                    .frame(width: Metrics.undoPillTimer * 0.45, height: Metrics.undoPillTimer * 0.45)
            }
        }
        .frame(width: Metrics.undoPillTimer, height: Metrics.undoPillTimer)
        .accessibilityHidden(true)
    }

    private static var isSnapshot: Bool { ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil }
}
