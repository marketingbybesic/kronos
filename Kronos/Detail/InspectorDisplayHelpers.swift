// Kronos/Detail/InspectorDisplayHelpers.swift — split out of InspectorScreen.swift purely to
// stay under the 500-line file cap: display-name extensions and small shared view helpers,
// no dependency on InspectorScreen's own state.
import SwiftUI
import KronosCore

// ForEach(KEffort.allCases)/ForEach(KPriority.allCases) require Identifiable; both are
// frozen Core Int-raw enums, so identity is just the raw value — a local conformance,
// not a Core change.
extension KEffort: @retroactive Identifiable {
    public var id: Int { rawValue }
}
extension KPriority: @retroactive Identifiable {
    public var id: Int { rawValue }
}

extension KEffort {
    /// Full name — used in the dropdown's menu items and for accessibility.
    var displayName: String {
        switch self {
        case .none: String(localized: "effort.none")
        case .xs: String(localized: "effort.xs")
        case .s: String(localized: "effort.s")
        case .m: String(localized: "effort.m")
        case .l: String(localized: "effort.l")
        case .xl: String(localized: "effort.xl")
        }
    }

    /// Short button-face text (already short in the catalog: XS/S/M/L/XL are the values
    /// themselves; only "No effort" needs shortening so three columns fit one row).
    var shortDisplayName: String {
        self == .none ? "—" : displayName
    }
}

extension KPriority {
    /// Full name — used in the dropdown's menu items and for accessibility.
    var displayName: String {
        switch self {
        case .none: String(localized: "priority.none")
        case .low: String(localized: "priority.low")
        case .medium: String(localized: "priority.medium")
        case .high: String(localized: "priority.high")
        case .urgent: String(localized: "priority.urgent")
        }
    }

    /// Button-face text: the word next to the bars, so priority reads like Effort and
    /// Deadline instead of a glyph alone. "None" is a dash like Effort's. Where three columns
    /// cannot fit the word, attributesRow's ViewThatFits drops to two rows.
    var shortDisplayName: String { self == .none ? "—" : displayName }
}

/// Small helper so a text field can revert on Esc without every call site re-writing the
/// same key handler.
extension View {
    /// Keeps a view mounted (so a sheet it hosts still presents) while it takes no space, shows
    /// nothing and is skipped by hit-testing and VoiceOver.
    func kCollapsedHost(_ collapsed: Bool) -> some View {
        opacity(collapsed ? 0 : 1)
            .frame(height: collapsed ? 0 : nil)
            .clipped()
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }

    func kOnEscapeRevert(active: Bool, _ revert: @escaping () -> Void) -> some View {
        onKeyPress(.escape) {
            guard active else { return .ignored }
            revert()
            return .handled
        }
    }
}

/// Section caption matching KSectionHeader's typography (uppercase, tracked, tertiary)
/// without its sidebar-specific leading inset (`Metrics.sidebarRowLeading`) and gap
/// metrics (`sidebarSectionGapTop/Bottom`) — KSectionHeader is built for the sidebar's
/// own icon-column rhythm, and reusing it here put every caption ~10pt to the right of
/// the content below it (caught in review). This shares one leading edge with everything
/// else in this screen's VStack instead.
struct InspectorSectionCaption: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Typo.sectionHdr)
            .textCase(.uppercase)
            .tracking(Tracking.caption)
            .foregroundStyle(Tok.textTertiary)
    }
}
