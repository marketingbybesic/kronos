// Kronos/DesignSystem/DynamicType.swift
// OS Dynamic Type (System Settings > Accessibility > Display > Text size, or the trackpad/
// keyboard "Larger Text" controls) as a SECOND multiplier layered on top of the app's own
// DSScale S/M/L setting (DSScale.swift). the internal notes §13.3 wants a
// `Font.kronos(_:weight:)` helper that scales with the OS setting but clamps at 1.35x so the
// three-pane layout never breaks; SwiftUI ships no `.scaled(clampedTo:)` primitive (that spec
// snippet is illustrative, not real API), and `Font` has no `@Environment` access outside a
// View body, so the clamped multiplier is computed from ONE root observation point
// (`AppShellView`'s `@Environment(\.dynamicTypeSize)`) and pushed into a plain mutable static —
// the exact same live-update pattern `DSScale` already uses for its own S/M/L setting (see
// DSScale.swift's header comment).
//
// Coexistence with DSScale (genuinely under-specified by the spec; this is the chosen
// behaviour): the two multiply — `base * DSScale.text * OSDynamicType.multiplier`. In practice
// this composes cleanly rather than competing, because `kronosMultiplier` below is exactly 1.0
// for every ordinary size (`.xSmall` through `.large`, which is where almost every Mac sits) —
// DSScale alone governs the normal S/M/L range, unchanged from today. The OS multiplier only
// becomes a real second factor once a user has actually turned on a Larger-Text accessibility
// size (`.xLarge` and up), at which point the two axes are independent and intentionally
// compose (same idea as browser zoom and in-page font-size settings both applying at once).
// Stacking DSScale L (1.1x) with the OS ceiling (1.35x) can reach ~1.49x over a token's raw
// base — accepted, since `OSDynamicType.clampCeiling` already guarantees the OS's OWN
// contribution never exceeds 1.35x of what DSScale already produced, which is the literal
// promise spec §13.3 makes ("clamped... to 1.0...1.35").
import SwiftUI

public enum OSDynamicType {
    /// Spec §13.3's stated ceiling: "a stated ceiling, not an oversight... past 1.35x the app
    /// stops scaling and the user's OS-level zoom takes over."
    public static let clampCeiling: CGFloat = 1.35
    /// Live multiplier, written only by `apply(_:)` from the one root observation point.
    public private(set) static var multiplier: CGFloat = 1.0

    /// A gentler ramp than `multiplier` for glyph-box constants (status circle, priority glyph,
    /// project dot): half the text ramp's growth, so icons grow "modestly" rather than matching
    /// text 1:1. Still capped by construction, since `multiplier` already is.
    public static var glyphMultiplier: CGFloat { 1.0 + (multiplier - 1.0) * 0.5 }

    /// Called from `AppShellView`'s `.onAppear`/`.onChange(of: dynamicTypeSize)` — the one place
    /// in the app that has `@Environment(\.dynamicTypeSize)` in scope for the main window.
    public static func apply(_ size: DynamicTypeSize) {
        multiplier = min(clampCeiling, max(1.0, size.kronosMultiplier))
    }
}

private extension DynamicTypeSize {
    /// SwiftUI ships no numeric multiplier for `DynamicTypeSize`; these approximate the real
    /// system Dynamic Type steps (roughly a 3x range end to end), floored at 1.0 for every size
    /// at or below `.large` (today's OS default — DSScale alone governs that range, see file
    /// header) and ramped through the five accessibility sizes up to the clamp ceiling.
    var kronosMultiplier: CGFloat {
        switch self {
        case .xSmall, .small, .medium, .large: return 1.0
        case .xLarge: return 1.08
        case .xxLarge: return 1.16
        case .xxxLarge: return 1.24
        case .accessibility1: return 1.28
        case .accessibility2: return 1.31
        case .accessibility3: return 1.33
        case .accessibility4: return 1.34
        case .accessibility5: return 1.35
        @unknown default: return 1.0
        }
    }
}

public extension Font {
    /// Every `Typo.*` token's font: `base` scaled by the app's own text-size setting
    /// (`DSScale.text`) and by the clamped OS Dynamic Type multiplier (see file header),
    /// floored at `Typo.minPointSize`. Weight and design never scale, only the point size.
    static func kronos(_ base: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let size = max(Typo.minPointSize, base * DSScale.text) * OSDynamicType.multiplier
        return .system(size: size, weight: weight, design: design)
    }
}
