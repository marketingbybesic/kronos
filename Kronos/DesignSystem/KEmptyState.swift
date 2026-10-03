// Kronos/DesignSystem/KEmptyState.swift
// Icon + one calm line, an optional purpose line and an optional next step. No exclamation
// marks, per the app's tone rule. Usage:
//   KEmptyState(icon: "inbox", title: "Nothing waiting for a home.")
//   KEmptyState(icon: "hourglass", title: "Nothing to wait on.", message: "Tasks you wait on land here.",
//               action: .init(title: "Show all tasks") { ... })
import SwiftUI

public struct KEmptyState: View {
    /// The one next step an empty screen offers: a button under the text.
    public struct Action {
        let title: String
        let run: () -> Void

        public init(title: String, run: @escaping () -> Void) {
            self.title = title
            self.run = run
        }
    }

    let icon: String
    let title: String
    var message: String?
    var action: Action?

    public init(icon: String, title: String, message: String? = nil, action: Action? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }

    /// The older spelling of the same thing (title + closure).
    public init(icon: String, title: String, message: String? = nil, actionTitle: String?, onAction: (() -> Void)?) {
        let action = actionTitle.flatMap { t in onAction.map { Action(title: t, run: $0) } }
        self.init(icon: icon, title: title, message: message, action: action)
    }

    public var body: some View {
        VStack(spacing: Space.x2) {
            Icon(icon, size: Metrics.iconXL + 12)
                .foregroundStyle(Tok.textDisabled)   // decoration only; the text carries the meaning
                .padding(.bottom, Space.x2)
                .accessibilityHidden(true)
            Text(title)
                .font(Typo.rowStrong)
                .foregroundStyle(Tok.textSecondary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.title, action: action.run)
                    .kButton(.secondary)
                    .uiTestAnchor("empty.action")
                    .padding(.top, Space.x2)
            }
        }
        .frame(maxWidth: 320)
        .padding(Space.x6)
        .accessibilityElement(children: .contain)
    }
}
