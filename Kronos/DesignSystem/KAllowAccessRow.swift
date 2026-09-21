// Kronos/DesignSystem/KAllowAccessRow.swift
// The calm, non-modal "Allow access in System Settings" row every access-gated feature needs
// (Settings > Coach's calendar row, Settings > Notes, and any future gated feature). Never
// appears unless the caller has already checked the real status — this view has no opinion of
// its own about when to show. A shared component (originally local to
// Kronos/Settings/SettingsCoachTab.swift) so every call site uses the same name and signature.
import SwiftUI

public struct KAllowAccessRow: View {
    let message: String
    let buttonTitle: String
    let action: () -> Void

    public init(message: String, buttonTitle: String, action: @escaping () -> Void) {
        self.message = message
        self.buttonTitle = buttonTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.x3) {
            Icon("key", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            Text(message)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.x2)
            Button(buttonTitle, action: action)
                .kButton(.secondary, size: .compact)
                .fixedSize()
        }
        .padding(.vertical, Space.x1)
    }
}
