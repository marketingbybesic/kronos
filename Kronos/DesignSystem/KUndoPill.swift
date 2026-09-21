// Kronos/DesignSystem/KUndoPill.swift
// 5-second undo affordance with a draining ring (spec §5.13's UndoChip, redrawn for the
// Ordo popover). The window is Tok.Motion.undoWindow so every undo affordance in the
// app shares one timing constant. Reduce Motion: the ring becomes a static remainder
// arc rather than animating, but the timer itself still expires at 5s (⌘Z always works
// regardless of whether the pill is visible).
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

    public func show(_ message: String) {
        current = ListUndoState(message: message)
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
    public static func == (a: ListUndoState, b: ListUndoState) -> Bool { a.id == b.id }
}

public struct KUndoPill: View {
    let message: String
    let onUndo: () -> Void
    let onExpire: () -> Void
    var duration: Double
    @State private var progress: Double = 1.0   // 1 -> 0 over `duration`

    public init(message: String, duration: Double = Motion.undoWindow, onUndo: @escaping () -> Void, onExpire: @escaping () -> Void) {
        self.message = message
        self.duration = duration
        self.onUndo = onUndo
        self.onExpire = onExpire
    }

    public var body: some View {
        HStack(spacing: Space.x2) {
            ZStack {
                Circle().stroke(Tok.hairline, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Tok.textTertiary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            Text(message)
                .font(Typo.meta)
                .foregroundStyle(Tok.textSecondary)
            Button(String(localized: "undo.action"), action: onUndo)
                .font(Typo.metaStrong)
                .buttonStyle(.plain)
                .foregroundStyle(Tok.textPrimary)
                .frame(minHeight: Metrics.minHit)
        }
        .padding(.horizontal, Space.x3)
        .frame(height: 32)
        .background(Tok.overlay)
        .kBorder(Tok.borderControl, radius: Radius.full)
        .clipShape(RoundedRectangle(cornerRadius: Radius.full, style: .continuous))
        .onAppear {
            if Motion.reduceMotion {
                // No animation, but the timer still expires the pill at `duration`.
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { onExpire() }
            } else {
                withAnimation(.linear(duration: duration)) { progress = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { onExpire() }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
