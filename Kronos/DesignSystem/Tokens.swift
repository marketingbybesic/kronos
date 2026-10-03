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
    /// OLED black applies everywhere, floating surfaces included — a deliberate design decision, re-confirmed
    /// 29.09.2026 after a rev-18 draft had turned it grey (#1B1B1F). Kept as its own token so
    /// the decision stays in one place.
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
    /// 0.52, not the bare 4.5:1 alpha over black (0.46): tertiary text also sits on hover,
    /// selected, pressed and project-tint fills, and must keep 4.5:1 on every one of them.
    /// Increase Contrast lifts it to 0.66 so it still clears 4.5:1 on the stronger IC selected
    /// fill (`selectedFillIC`, hue x `selectedTintOpacityIC`). verify-contrast.mjs checks both.
    public static let textTertiary  = KTone.white(0.52, increasedContrast: 0.66)
    /// Glyph-only decoration (an empty-state icon, a hover check preview). Never readable text,
    /// never a live control's label: below the 4.5:1 text floor and the 3:1 glyph floor.
    /// Increase Contrast maps it to the secondary tone (0.66), like tertiary, so a disabled control or
    /// a quiet glyph is never fainter than the lowest readable step.
    public static let textDisabled  = KTone.white(0.30, increasedContrast: 0.66)
    /// Empty indicator steps (unfilled priority bars / effort dots). Decoration, never text.
    /// 0.20, so an empty step is still perceivable next to a filled one.
    public static let glyphEmpty    = Color(white: 1, opacity: 0.20)
    public static let textOnAccent  = Color.black   // label colour on the white primary fill

    // MARK: Focus / selection — white, not a hue. Second channel is a white bar/ring,
    // never colour, since colour is reserved for user data.
    public static let focusRing = Color(white: 1, opacity: 0.70)
    /// Accent-hue focus ring / nest outline: the user's accent faded to this, so a 1 pt line reads
    /// as a fine glow rather than a frame. 0.80 is the lowest single opacity at which every
    /// `AccentPalette` swatch keeps `ringContrastFloor` over black (electric needs 0.79); a custom
    /// colour that is darker still is lifted further by `KRing.opacity(for:)`. Increase Contrast
    /// restores full opacity.
    public static let ringAccentOpacity: Double = 0.80
    /// Non-text indicators (focus ring, nest outline) must read at 3:1 against black at the
    /// opacity they are actually drawn at (WCAG 1.4.11).
    public static let ringContrastFloor: Double = 3.0
    /// Faint accent wash over a keyboard-focused control (with the ring), and the slightly
    /// stronger one over a drag-nest target. Over #000 these read as a tint, never a surface.
    public static let focusTintOpacity: Double = 0.07
    public static let nestTintOpacity: Double = 0.11

    // MARK: State fills — always paired with a second channel (border, bar, icon).
    public static let hoverFill    = Color.white.opacity(0.045)
    public static let pressedFill  = Color.white.opacity(0.10)
    /// Selection = this fill + a 0.5 pt inner hairline (`selectedEdge`) + the 2 pt bar.
    public static let selectedFill = Color.white.opacity(0.07)
    public static let selectedEdge = Color.white.opacity(0.06)
    /// A selected row in a hue (project colour or the user's accent): the hue over #000 at this
    /// opacity, so it reads about as strong as the neutral `selectedFill` does. See `KSelection`.
    public static let selectedTintOpacity: Double = 0.16
    /// Increase Contrast versions of the selection fill: the neutral fill doubles, a hue fill is
    /// 1.6x stronger. Tertiary text keeps 4.5:1 on both (verify-contrast.mjs).
    public static let selectedFillIC = Color.white.opacity(0.14)
    public static let selectedTintOpacityIC: Double = 0.256
    public static let dropFill     = Color.white.opacity(0.12)
    /// The resting fill of a quiet control (secondary button, field, segmented track):
    /// a control reads as a faint plate, not as an outlined box.
    public static let controlFill  = Color.white.opacity(0.055)
    /// A key cap's plate (KKeyCap).
    public static let keycapFill   = Color.white.opacity(0.08)
    /// A passive tag's plate (KTag): a value, not a control, so no border and no hover.
    public static let tagFill      = Color.white.opacity(0.06)
    /// A quiet plate in a caller's hue (KBadge's subtle style, a project glyph's tile).
    public static let tintSubtle: Double = 0.14
    /// The selected segment's marker in the accent (KSegmented), so a white accent keeps the
    /// former neutral 0.12 plate.
    public static let markerTintOpacity: Double = 0.12
    /// A drag's ghost insertion line: the accent faded so the solid line stays the stronger one.
    public static let dropLineOpacity: Double = 0.55
    /// The primary button's accent fill at rest, under the pointer and pressed.
    public static let primaryFill: Double = 0.92
    public static let primaryFillHover: Double = 1.0
    public static let primaryFillPressed: Double = 0.80
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
    /// KChip and KTag, the same corner as a control so chips and buttons read as one family.
    public static let chip: CGFloat    = 6
    /// A key cap: smaller than a chip, it is a glyph-sized plate.
    public static let keycap: CGFloat  = 3
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
    /// macOS minimum text size (HIG). No token renders smaller at any text size.
    public static let minPointSize: CGFloat = 10
    /// `base` scaled by the text size, never below `minPointSize`. Every token whose base x the
    /// smallest scale (S 0.92) would fall under the floor goes through this.
    public static func size(_ base: CGFloat) -> CGFloat { max(minPointSize, base * DSScale.text) }

    public static var title        : Font { .system(size: 20 * DSScale.text, weight: .semibold) }
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
    /// Uppercase tracked micro label ("FIRST MOVE", "AREAS"). 10 pt at S and M, 11 at L.
    public static var caption       : Font { .system(size: size(10), weight: .semibold) }
    /// A count inside a small round badge (the view-options rule count).
    public static var badge         : Font { .system(size: size(10), weight: .bold).monospacedDigit() }
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

    public static var rowHeight: CGFloat         { 40 * DSScale.density }   // list row, spec B3 (rev18: 36→40 for readability)
    public static var rowHeightDense: CGFloat    { 28 * DSScale.density }
    public static var rowHeightDrag: CGFloat     { 40 * DSScale.density }
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
    /// Vertical gap between inspector sections (title, first move, attributes, links, steps,
    /// notes, details): one value on the 4 pt grid.
    public static let inspectorSectionGap: CGFloat   = Space.x6
    /// Interactive pill (KChip): equals `minHit`, so the chip is its own hit target.
    public static let chipHeight: CGFloat            = 24
    /// Passive pill (KTag): a value inside a row, never a target.
    public static let tagHeight: CGFloat             = 16
    public static let badgeHeight: CGFloat           = 18
    /// The round count badge on an icon button (KViewOptionsIconButton).
    public static let countBadge: CGFloat            = 14
    public static let undoPillHeight: CGFloat        = 36
    /// A long message truncates inside the pill instead of widening it.
    public static let undoPillMaxWidth: CGFloat      = 560
    /// The undo pill's countdown ring (and the check inside it).
    public static let undoPillTimer: CGFloat         = 14
    public static let undoPillTimerStroke: CGFloat   = 2
    /// Colour swatch in a picker grid (inside a `minHit` target).
    public static let swatch: CGFloat                = 20
    public static let strokeQuiet: CGFloat           = 1.25  // checkbox / Complete ring stroke
    public static let strokeHair: CGFloat            = 0.5   // selection's inner hairline
    public static let hairline: CGFloat              = 1     // KHairline divider thickness
    public static let ringWidth: CGFloat             = 1     // focus ring / nest outline hairline
    public static let ringGap: CGFloat               = 2     // clear space between a control and its focus ring
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
    /// The one completion reward: a 1 pt accent ring around a just-checked checkbox grows from
    /// 1x to `completeRippleScale` while fading from `completeRippleOpacity` to 0.
    public nonisolated static let completeRipple: Double = 0.26
    public nonisolated static let completeRippleScale: CGFloat = 1.7
    public nonisolated static let completeRippleOpacity: Double = 0.6
    /// Half-period of the Now card's attention pulse and of the tour's breathing spotlight,
    /// and one tour step transition. Loops never run under Reduce Motion.
    public nonisolated static let attentionLoop: Double = 1.2
    public nonisolated static let breathLoop: Double = 1.6
    public nonisolated static let tour: Double = 0.32

    /// True when the user has Reduce Motion on, or a test run asked for the reduced path with
    /// `KRONOS_REDUCE_MOTION=1` (snapshots and the live test never flip the person's System
    /// Settings). Re-read each call — it can change live.
    public static var reduceMotion: Bool {
        ProcessInfo.processInfo.environment["KRONOS_REDUCE_MOTION"] == "1"
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whether the completion ripple runs: never under Reduce Motion (the check still appears,
    /// only the spatial ring is skipped).
    public static func ripples(reduceMotion: Bool) -> Bool { !reduceMotion }

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
    /// The completion ripple's growth and fade.
    public static var ripple: Animation   { quart(completeRipple) }
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
