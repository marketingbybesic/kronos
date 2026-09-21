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

    /// Button-face text is empty: the bars glyph already carries the level, name shown in
    /// tooltip/accessibility instead, and "Medium"/"Urgent" were the words that didn't fit a
    /// 3-column row at 360pt. Full name still reads through displayName in the dropdown and
    /// the accessibility label.
    var shortDisplayName: String { "" }
}

/// Small helper so a text field can revert on Esc without every call site re-writing the
/// same key handler.
extension View {
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
            .tracking(0.5)
            .foregroundStyle(Tok.textTertiary)
    }
}
