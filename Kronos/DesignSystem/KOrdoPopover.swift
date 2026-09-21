// Kronos/DesignSystem/KOrdoPopover.swift
// Content for the popover that drops from the menu bar Ordo item: list name, task
// title, first-move line, a big calm circular complete control, and an empty state.
// The 5s undo pill (KUndoPill) is shown by the caller above/below this content when a
// completion just happened — kept separate so this view has one job (show the queue).
// Usage: KOrdoPopover(taskTitle: "...", firstMove: "...", remaining: 4, onComplete: {})
import SwiftUI

public struct KOrdoPopover: View {
    let taskTitle: String?
    let firstMove: String?
    let remaining: Int
    let onComplete: () -> Void
    @State private var isPressed = false

    public init(taskTitle: String?, firstMove: String?, remaining: Int, onComplete: @escaping () -> Void) {
        self.taskTitle = taskTitle
        self.firstMove = firstMove
        self.remaining = remaining
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: Space.x4) {
            HStack {
                Text(String(localized: "ordo.title"))
                    .font(Typo.heading)
                    .foregroundStyle(Tok.textPrimary)
                Spacer()
                Text(String(format: String(localized: "menubar.ordo.remaining"), "\(remaining)"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }

            if let taskTitle {
                VStack(spacing: Space.x4) {
                    VStack(spacing: Space.x1) {
                        if let firstMove {
                            Text(firstMove)
                                .font(Typo.heading)
                                .foregroundStyle(Tok.textPrimary)
                                .multilineTextAlignment(.center)
                        }
                        Text(taskTitle)
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: onComplete) {
                        Circle()
                            .strokeBorder(Tok.textSecondary, lineWidth: 1.5)
                            .background(Circle().fill(isPressed ? Color.white.opacity(0.08) : .clear))
                            .overlay(Icon("check", size: 22).foregroundStyle(Tok.textSecondary))
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(isPressed ? 0.94 : 1)
                    .animation(Motion.curve(Motion.fast), value: isPressed)
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {} onPressingChanged: { pressing in
                        isPressed = pressing
                    }
                    .accessibilityLabel(String(localized: "menubar.ordo.complete"))
                    // GAP (reported): no catalog key for this hint's exact text
                    // ("Completes the next subtask, or the task") — left as English
                    // rather than inventing a translation; report to whoever owns
                    // Localizable.xcstrings.
                    .accessibilityHint("Completes the next subtask, or the task")
                }
                .padding(.vertical, Space.x4)
            } else {
                KEmptyState(icon: "list-ordered", title: String(localized: "bar.empty"))
                    .padding(.vertical, Space.x4)
            }
        }
        .padding(Space.x4)
        .frame(width: 280)
        .background(Tok.overlay)
    }
}
