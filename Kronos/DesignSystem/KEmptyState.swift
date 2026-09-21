// Kronos/DesignSystem/KEmptyState.swift
// Icon + one calm line. No exclamation marks, per the app's tone rule. Usage:
//   KEmptyState(icon: "inbox", title: "Nothing waiting for a home.")
import SwiftUI

public struct KEmptyState: View {
    let icon: String
    let title: String
    var message: String?
    var actionTitle: String?
    var onAction: (() -> Void)?

    public init(icon: String, title: String, message: String? = nil, actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    public var body: some View {
        VStack(spacing: Space.x2) {
            Icon(icon, size: Metrics.iconXL + 12)
                .foregroundStyle(Tok.textDisabled)
                .padding(.bottom, Space.x2)
            Text(title)
                .font(Typo.rowStrong)
                .foregroundStyle(Tok.textSecondary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .kButton(.secondary)
                    .padding(.top, Space.x2)
            }
        }
        .frame(maxWidth: 320)
        .padding(Space.x6)
    }
}
