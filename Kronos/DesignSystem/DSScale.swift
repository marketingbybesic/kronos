// Kronos/DesignSystem/DSScale.swift
// Feature I density/text-size scale (Settings > Appearance). `Typo` scales by `.text`;
// `Metrics` row heights, list/sidebar row spacing and control heights scale by `.density`;
// hairlines, radii and icon strokes never scale (spec: geometry that reads as a boundary
// must stay put). Every value defaults to the regular/M multiplier (1.0), so a screen
// rendered before `apply(...)` runs (a gallery preview or a test target that never calls
// AppDelegate) is pixel-identical to today.
//
// LIVE UPDATE: `density`/`text` are plain statics with no observation of their own —
// `Metrics.rowHeight` etc. are computed properties, not `@Environment`/`@Observable` reads, so
// SwiftUI has nothing to invalidate when they change. `apply(...)` used to be called only once,
// before the first window, which is why a Settings change never took effect without a
// relaunch. The fix does not make DSScale itself observable (a plain enum's statics can't be —
// nothing @Observable holds a reference to it); instead `apply(...)` is called again the
// moment Settings changes the value, and the caller then bumps `model.didMutate()`
// (SettingsAppearanceTab does this in its onChange handlers). Every mounted screen already
// re-evaluates its body on `model.version` (TaskListScreen.swift:64 among others) — that
// existing re-render picks up the freshly-applied DSScale value with no new observation
// machinery.
import CoreGraphics

public enum DSScale {
    public static var density: CGFloat = 1.0   // compact 0.86 / regular 1.0
    public static var text: CGFloat = 1.0      // S 0.92 / M 1.0 / L 1.1

    /// `CoachSettings.density`/`.textSize` are the raw stored strings ("compact"/"regular",
    /// "S"/"M"/"L") — this maps them to the multipliers so AppDelegate stays a two-line call
    /// with no scaling arithmetic of its own, and an unrecognised value degrades to 1.0.
    /// Safe to call more than once: a live Settings change calls this again, then the caller
    /// bumps `model.didMutate()` so the currently mounted screens pick it up immediately.
    public static func apply(density densityRaw: String, textSize textSizeRaw: String) {
        density = densityRaw == "compact" ? 0.86 : 1.0
        text = ["S": 0.92, "M": 1.0, "L": 1.1][textSizeRaw] ?? 1.0
    }
}
