// Kronos/DesignSystem/Tokens.swift
// Color tokens. OLED-black direction: every surface is pure #000000; elevation reads
// through hairlines and faint white fills, never grey slabs. FULLY MONOCHROME chrome —
// no accent hue, no semantic hue (priority/amber/green) anywhere in app chrome. The only
// colour anywhere in the UI is user DATA: a project's own colour (KProjectGlyph / sidebar
// dot) and the swatches inside KColorSwatchPicker — both live outside `Tok` (see
// KProjectPalette).
//
// verify-contrast.mjs parses this file directly: keep every text/icon/border token as
// `Color(white: 1, opacity: <alpha>)` (contrast == the alpha's own ratio over black) or
// `Color(hex: 0x......)` (opaque hue, contrast computed via relative luminance), so the
// script can compute real WCAG numbers without a hand-copied list.
import SwiftUI

public enum Tok {

    // MARK: Ground — pure OLED black everywhere, no grey panels.
    public static let bg      = Color.black
    public static let surface = Color.black
    public static let raised  = Color.black
    /// Popovers/menus/sheets lift one step off pure black so they read as floating;
    /// elevation is still carried by border + shadow, never by this fill alone.
    /// OLED black applies everywhere, floating surfaces included (the menu-bar popover
    /// already was). Kept as its own token so the decision stays in one place.
    public static let overlay = Color.black

    // MARK: Borders — the only way elevation and control boundaries read on true black.
    /// Decorative dividers only. Never a control's sole boundary (contrast-exempt).
    public static let hairline = Color(white: 1, opacity: 0.07)
    /// Control outlines. Below 3:1 alone by design — always paired with a fill plus
    /// the control's own label/icon contrast, which passes independently (spec §2.1).
    public static let borderControl = Color(white: 1, opacity: 0.12)
    /// Hover/pressed border step. Decorative-adjacent, paired with a fill change.
    public static let borderStrong = Color(white: 1, opacity: 0.20)
    /// Selected/active control edges that must read as a boundary on their own (~3.9:1).
    public static let borderActive = Color(white: 1, opacity: 0.42)

    // MARK: Text — style G's three tones, alpha tiers over pure black. The steps are
    // deliberately far apart so hierarchy reads from tone alone: PRIMARY = titles and the
    // one hero line per pane; SECONDARY = values, counts, active controls; TERTIARY =
    // captions, idle glyphs, placeholders. Nothing decorative may be primary.
    public static let textPrimary   = Color(white: 1, opacity: 0.94)   // ~18:1, off pure white: no OLED glare
    public static let textSecondary = Color(white: 1, opacity: 0.66)   // ~8.7:1
    public static let textTertiary  = Color(white: 1, opacity: 0.47)   // ~4.7:1, the AA floor
    /// Non-text-critical decoration only — below the 4.5:1 body-text floor.
    public static let textDisabled  = Color(white: 1, opacity: 0.30)
    /// Empty indicator steps (unfilled priority bars / effort dots). Decoration, never text.
    public static let glyphEmpty    = Color(white: 1, opacity: 0.12)
    public static let textOnAccent  = Color.black   // label colour on the white primary fill

    // MARK: Focus / selection — white, not a hue. Second channel is a white bar/ring,
    // never colour, since colour is reserved for user data.
    public static let focusRing = Color(white: 1, opacity: 0.70)

    // MARK: State fills — always paired with a second channel (border, bar, icon).
    public static let hoverFill    = Color.white.opacity(0.045)
    public static let pressedFill  = Color.white.opacity(0.10)
    /// Selection = this fill + a 0.5 pt inner hairline (`selectedEdge`) + the 2 pt bar.
    public static let selectedFill = Color.white.opacity(0.07)
    public static let selectedEdge = Color.white.opacity(0.06)
    public static let dropFill     = Color.white.opacity(0.12)
    /// The resting fill of a quiet control (secondary button, field, segmented track):
    /// a control reads as a faint plate, not as an outlined box.
    public static let controlFill  = Color.white.opacity(0.055)
    // No destructive/red token exists by design: Kronos never uses red (SPEC hard constraint 9).
    // A destructive menu item is distinguished by wording and position, not colour.

    /// A sheet/panel's dimming scrim behind a modal (Impuls, palette, project editor).
    /// Black, not the system's translucent material — OLED rule (no vibrancy anywhere).
    public static let scrim = Color.black.opacity(0.6)
}

public enum Space {
    public static let x1: CGFloat = 4
    public static let x2: CGFloat = 8
    public static let x3: CGFloat = 12
    public static let x4: CGFloat = 16
    public static let x5: CGFloat = 20
    public static let x6: CGFloat = 24
    public static let x8: CGFloat = 32
}

public enum Radius {
    public static let row: CGFloat     = 6
    public static let chip: CGFloat    = 4
    public static let card: CGFloat    = 10
    public static let control: CGFloat = 6
    public static let popover: CGFloat = 12
    public static let bar: CGFloat     = 32
    /// Large enough to fully round any control this app draws (pills, circular buttons).
    public static let full: CGFloat    = 999
}

// Every size below is scaled live by `DSScale.text` (Settings > Appearance text size: S 0.92 /
// M 1.0 / L 1.1) — `static var` computed, not `let`, so a change takes effect on the next
// render with no cache to invalidate. Weight/design/tracking never scale, only the point size.
public enum Typo {
    public static var title         : Font { .system(size: 20 * DSScale.text, weight: .semibold) }
    public static var heading       : Font { .system(size: 15 * DSScale.text, weight: .semibold) }
    public static var sectionHdr    : Font { .system(size: 11 * DSScale.text, weight: .semibold) }
    public static var row           : Font { .system(size: 13 * DSScale.text, weight: .regular) }
    public static var rowStrong     : Font { .system(size: 13 * DSScale.text, weight: .medium) }
    public static var meta          : Font { .system(size: 11 * DSScale.text, weight: .regular) }
    public static var metaStrong    : Font { .system(size: 11 * DSScale.text, weight: .medium) }
    public static var body          : Font { .system(size: 13 * DSScale.text, weight: .regular) }
    public static var mono          : Font { .system(size: 12 * DSScale.text, design: .monospaced) }
    // Style G additions. Pair display/hero/title with `Tracking.tight`, caption with
    // `Tracking.caption` (`.tracking(...)` is a Text/View modifier, so it cannot live in a Font).
    /// Pane title ("All", "Today").
    public static var display       : Font { .system(size: 24 * DSScale.text, weight: .semibold) }
    /// The one hero line of a pane: the first move on the Now card.
    public static var hero          : Font { .system(size: 22 * DSScale.text, weight: .semibold) }
    /// The supporting line under a hero (task title on the Now card).
    public static var lead          : Font { .system(size: 14 * DSScale.text, weight: .regular) }
    /// Uppercase tracked micro label ("FIRST MOVE", "AREAS").
    public static var caption       : Font { .system(size: 10 * DSScale.text, weight: .semibold) }
    /// Every count, date and duration: tabular numerals so columns do not jitter.
    public static var count         : Font { .system(size: 11 * DSScale.text, weight: .regular).monospacedDigit() }
    public static var rowTabular    : Font { .system(size: 13 * DSScale.text, weight: .regular).monospacedDigit() }
}

public enum Tracking {
    public static let tight: CGFloat   = -0.3
    public static let row: CGFloat     = -0.1
    public static let caption: CGFloat = 1.1
}

public enum Metrics {
    // Control heights, row heights and row spacing scale live with `DSScale.density`
    // (Settings > Appearance: compact 0.86 / regular 1.0) — `static var`, not `let`, so a
    // density change takes effect on the next render. Hairlines, radii and icon strokes
    // never scale (they read as fixed boundaries, not breathing room).
    public static var controlCompact: CGFloat { 28 * DSScale.density }
    public static var controlRegular: CGFloat { 32 * DSScale.density }

    public static var rowHeight: CGFloat         { 36 * DSScale.density }   // list row, spec B3
    public static var rowHeightDense: CGFloat    { 28 * DSScale.density }
    public static var rowHeightDrag: CGFloat     { 36 * DSScale.density }
    public static var groupHeaderHeight: CGFloat { 28 * DSScale.density }
    public static let toolbarHeight: CGFloat     = 44
    public static let composerHeight: CGFloat    = 44

    public static let statusCircle: CGFloat      = 16
    public static let listCheckboxSize: CGFloat  = 16   // style G: 16pt, quiet ring (was 18)
    public static let priorityGlyph              = CGSize(width: 14, height: 12)
    public static let projectDot: CGFloat        = 6
    public static let hitSlop: CGFloat           = 4
    public static let minHit: CGFloat            = 24

    public static let iconXS: CGFloat = 10
    public static let iconS: CGFloat  = 12
    public static let iconM: CGFloat  = 14
    public static let iconL: CGFloat  = 16
    public static let iconXL: CGFloat = 20

    public static let sidebarDefault: CGFloat   = 232
    public static let sidebarMin: CGFloat       = 180
    public static let sidebarMax: CGFloat       = 320
    public static let sidebarRail: CGFloat      = 56   // iconsOnly mode width
    public static let inspectorDefault: CGFloat = 380
    public static let inspectorMin: CGFloat     = 320
    public static let inspectorMax: CGFloat     = 520
    public static let listMin: CGFloat          = 420

    // MARK: Sidebar geometry (spec B1) — every number named, no magic literals in
    // KSidebarRow/KSectionHeader. Icons+text mode:
    //   [outer inset 8] row container [leading 10] icon(16 box) [gap 10] title … count [trailing 10]
    // Selection bar sits INSIDE the row, at its leading edge, inset 6 top/bottom — it
    // does not add to the icon's position (the icon column is fixed regardless of
    // selection state).
    public static let sidebarOuterInset: CGFloat     = 8    // pane edge -> row container
    public static var sidebarRowHeight: CGFloat      { 28 * DSScale.density }   // sidebar F: compact rows (was 32)
    public static let sidebarRowLeading: CGFloat     = 10   // row edge -> icon
    public static let sidebarIconBox: CGFloat        = 16   // icon column width, fixed regardless of glyph size
    public static let sidebarIconTextGap: CGFloat    = 8    // icon -> title
    public static let sidebarRowTrailing: CGFloat    = 10   // count/trailing -> row edge
    public static var sidebarRowVGap: CGFloat        { 1 * DSScale.density }    // gap between consecutive rows
    public static var sidebarSectionGapTop: CGFloat  { 20 * DSScale.density }   // above a section header
    public static var sidebarSectionGapBottom: CGFloat { 6 * DSScale.density }  // below a section header, before its first row
    public static let sidebarSelectionBarWidth: CGFloat  = 2
    public static let sidebarSelectionBarInset: CGFloat  = 6  // top/bottom inset of the selection bar within the row
    public static let sidebarRailIconSize: CGFloat   = 19    // icon size in iconsOnly mode (18-20pt)
    public static let sidebarIndentStep: CGFloat     = 14    // per indent level (project under an area)
    public static let sidebarRailRowHeight: CGFloat  = 32    // the rail keeps its larger target
    public static let sidebarDisclosure: CGFloat     = 9     // area chevron: quiet, smaller than any icon

    // MARK: Style G components
    public static let iconPickerCell: CGFloat        = 28
    public static let iconPickerColumns: Int         = 8
    public static let iconPickerGap: CGFloat         = 4
    public static let iconPickerViewport: CGFloat    = 236   // ~5 groups visible before scrolling
    public static let nowCardPadding: CGFloat        = 24
    public static let nowCardComplete: CGFloat       = 30    // the Now card's Complete ring
    public static let propertyLabelColumn: CGFloat   = 96    // KPropertyRow label column
    public static let strokeQuiet: CGFloat           = 1.25  // checkbox / Complete ring stroke
    public static let strokeHair: CGFloat            = 0.5   // selection's inner hairline
    public static let ruleFieldColumn: CGFloat       = 92    // sort/filter rule row: icon + field name
    public static let ruleOperatorColumn: CGFloat    = 48    // "is" / "is not" / "nije": value column starts at one x

    // MARK: List row geometry (spec B3) — mirrors the sidebar's rhythm.
    public static var listRowLeading: CGFloat        { 12 * DSScale.density }   // row edge -> checkbox
    public static var listCheckboxTitleGap: CGFloat  { 10 * DSScale.density }   // checkbox -> title
    public static var listRowTrailing: CGFloat       { 12 * DSScale.density }   // last trailing slot -> row edge
    public static var listTrailingSlotGap: CGFloat   { 8 * DSScale.density }    // between trailing metadata slots

    // MARK: Panel geometry (spec B2) — every KPanel-style block
    // (TriageCard, etc.) aligns to the same leading edge as everything else around it.
    public static let panelPadding: CGFloat          = 14

    // MARK: Popover / sheet widths — every leaf that builds a popover or a modal card
    // sizes to one of these named widths instead of a hand-picked literal.
    public static let popoverWidth: CGFloat          = 360  // KViewOptionsPopover's own width
    public static let paletteWidth: CGFloat          = 560  // command palette card
    public static let impulsCardWidth: CGFloat       = 520  // Impuls focus card
    /// Label column in a settings-style form (label ... control, aligned across rows).
    public static let settingsLabelColumn: CGFloat   = 140
    /// Emoji picker's scrollable grid viewport — tall enough for ~4 rows before scrolling.
    public static let pickerViewportHeight: CGFloat  = 176
}

@MainActor
public enum Motion {
    // Plain constants are `nonisolated` so they can be used as default parameter
    // values from non-isolated contexts (e.g. a View's synchronous init) — only
    // `reduceMotion`/`curve` actually need to touch the main-actor-isolated NSWorkspace.
    public nonisolated static let fast: Double       = 0.12
    public nonisolated static let medium: Double     = 0.18
    public nonisolated static let done: Double       = 0.24
    public nonisolated static let barSlide: Double   = 0.16
    public nonisolated static let undoWindow: Double = 5.0

    /// True when the user has Reduce Motion on. Re-read each call — it can change live.
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Every animation in the app goes through this, so Reduce Motion is one switch.
    public static func curve(_ duration: Double) -> Animation {
        reduceMotion ? .linear(duration: 0.001) : .easeOut(duration: duration)
    }

    // Style G presets (120-180 ms, ease-out, nothing bounces). Hover and selection happen
    // hundreds of times a day, so they are the shortest; completion is the one moment
    // allowed to be seen. Ease-out-quart: fast start, soft landing.
    private static func quart(_ duration: Double) -> Animation {
        reduceMotion ? .linear(duration: 0.001) : .timingCurve(0.25, 1, 0.5, 1, duration: duration)
    }
    public static var hover: Animation    { quart(fast) }
    public static var select: Animation   { quart(0.14) }
    public static var complete: Animation { quart(medium) }
    /// Popover / menu content: scale 0.98 -> 1 with a fade (see `kPopoverEntrance`).
    public static var popover: Animation  { quart(0.16) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
