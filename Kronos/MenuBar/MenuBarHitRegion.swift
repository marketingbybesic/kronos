// Kronos/MenuBar/MenuBarHitRegion.swift
// Clicking the CIRCLE glyph in the menu bar completes the focus task; clicking anywhere else
// in the status item toggles the popover. Pure geometry, no AppKit/SwiftUI dependency, so it
// can be proven correct by a standalone self-test (scripts/menubar-hit-selftest.swift)
// compiled with this file alone.
import Foundation

enum MenuBarHitRegion {
    enum Zone: Equatable { case circle, rest }

    /// `x` is the click location in the status item BUTTON's own coordinate space (origin at
    /// its leading edge, same space `NSStatusBarButton` hands a click handler). `circleWidth`
    /// is the rendered glyph's width in that same space — the circle occupies `[0, circleWidth)`
    /// starting at the button's leading edge, since the glyph is always drawn first, the title
    /// (if any) after it. A negative/zero `circleWidth` or a negative `x` never matches the
    /// circle: there is nothing to hit.
    static func region(forX x: CGFloat, circleWidth: CGFloat) -> Zone {
        guard circleWidth > 0, x >= 0, x < circleWidth else { return .rest }
        return .circle
    }
}
