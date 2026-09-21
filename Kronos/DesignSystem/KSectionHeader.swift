// Kronos/DesignSystem/KSectionHeader.swift
// Sidebar/list section header: uppercased label + optional hover-revealed trailing action.
// In iconsOnly sidebar mode the label has nowhere to sit legibly, so it collapses to a
// slim hairline divider with the action still reachable (opacity-revealed on hover, and
// always present for VoiceOver/keyboard).
//
// Geometry (spec B1): 20pt gap above the header, 6pt below before its first row, text
// leading-aligned to the SAME x-position as a row's icon (Metrics.sidebarRowLeading),
// not the row's own outer edge — so "AREAS" sits directly above where "Inbox"'s icon
// starts, not above the icon+bar gutter.
// Usage: KSectionHeader("Areas", trailingIcon: "plus", trailingLabel: "New area") { onAddArea() }
import SwiftUI

public struct KSectionHeader: View {
    let title: String
    var trailingIcon: String?
    var trailingLabel: String?
    var onTrailingTap: (() -> Void)?
    /// An empty section (e.g. no areas yet) needs a visible way in, so the trailing action
    /// skips the hover gate while the section is empty rather than staying invisible with
    /// nothing to hover over yet.
    var alwaysVisibleWhenEmpty: Bool = false
    @Environment(\.kSidebarMode) private var mode
    @State private var isHovering = false

    public init(_ title: String, trailingIcon: String? = nil, trailingLabel: String? = nil,
                alwaysVisibleWhenEmpty: Bool = false, onTrailingTap: (() -> Void)? = nil) {
        self.title = title
        self.trailingIcon = trailingIcon
        self.trailingLabel = trailingLabel
        self.alwaysVisibleWhenEmpty = alwaysVisibleWhenEmpty
        self.onTrailingTap = onTrailingTap
    }

    public var body: some View {
        Group {
            if mode == .iconsOnly {
                KHairline().padding(.horizontal, Metrics.sidebarRowLeading)
            } else {
                HStack {
                    Text(title)
                        .font(Typo.caption)
                        .textCase(.uppercase)
                        .tracking(Tracking.caption)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer()
                    trailingButton
                }
                .padding(.leading, Metrics.sidebarRowLeading)
                .padding(.trailing, Metrics.sidebarRowTrailing)
            }
        }
        .frame(height: Metrics.groupHeaderHeight)
        .padding(.top, Metrics.sidebarSectionGapTop)
        .padding(.bottom, Metrics.sidebarSectionGapBottom)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if let trailingIcon, let onTrailingTap {
            Button(action: onTrailingTap) {
                Icon(trailingIcon, size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
            .opacity((isHovering || alwaysVisibleWhenEmpty) ? 1 : 0)
            // Always present in the accessibility tree regardless of visual opacity
            // (spec §3.1) — VoiceOver users can reach it even while it's not hovered.
            .accessibilityHidden(false)
            .accessibilityLabel(trailingLabel ?? String(localized: "common.add"))
        }
    }
}
