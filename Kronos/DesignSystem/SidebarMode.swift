// Kronos/DesignSystem/SidebarMode.swift
// Sidebar display mode — user-switchable between a narrow icon rail and the full
// icon+text list. Read via @Environment(\.kSidebarMode) inside KSidebarRow and any
// sidebar-hosting container.
import SwiftUI

public enum KSidebarMode: String, CaseIterable {
    case iconsOnly
    case iconsAndText

    public var width: CGFloat {
        switch self {
        case .iconsOnly: return Metrics.sidebarRail
        case .iconsAndText: return Metrics.sidebarDefault
        }
    }
}

private struct KSidebarModeKey: EnvironmentKey {
    static let defaultValue: KSidebarMode = .iconsAndText
}

public extension EnvironmentValues {
    var kSidebarMode: KSidebarMode {
        get { self[KSidebarModeKey.self] }
        set { self[KSidebarModeKey.self] = newValue }
    }
}

/// Compact segmented control to flip between the two sidebar modes. Usage:
///   KSidebarModeToggle(mode: $sidebarMode)
public struct KSidebarModeToggle: View {
    @Binding var mode: KSidebarMode

    public init(mode: Binding<KSidebarMode>) {
        self._mode = mode
    }

    public var body: some View {
        HStack(spacing: 2) {
            segment(.iconsOnly, icon: "panel-right", label: String(localized: "sidebar.mode.icons"))
            segment(.iconsAndText, icon: "list-ordered", label: String(localized: "sidebar.mode.full"))
        }
        .padding(2)
        .background(Color.white.opacity(0.04))
        .kBorder(Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func segment(_ value: KSidebarMode, icon: String, label: String) -> some View {
        let isOn = mode == value
        return Button {
            withAnimation(Motion.curve(Motion.medium)) { mode = value }
        } label: {
            Icon(icon, size: Metrics.iconM)
                .foregroundStyle(isOn ? Tok.textPrimary : Tok.textTertiary)
                .frame(width: Metrics.controlCompact, height: Metrics.controlCompact - 4)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                        .fill(isOn ? Color.white.opacity(0.10) : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
