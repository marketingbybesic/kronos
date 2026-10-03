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
        region(forX: x, circleWidth: circleWidth, imageOrigin: 0, slop: 0)
    }

    /// The real geometry: `NSStatusBarButton` centres its image, so the glyph starts at
    /// `imageOrigin` = (button width - image width) / 2, not at 0 — with origin 0 a click on
    /// the drawn circle landed ~8 pt into the "rest" zone and opened the popover instead
    /// (user report: the circle did not respond). `slop` widens a 14 pt glyph into a comfortable target.
    ///
    /// `titleGap` is the space between the glyph and the first letter of the title. The target
    /// never grows past the title start, so a click on the first letters of the title (its
    /// first 4 pt included) opens the popover instead of completing the task by mistake.
    static func region(forX x: CGFloat, circleWidth: CGFloat, imageOrigin: CGFloat, slop: CGFloat,
                       titleGap: CGFloat = .infinity) -> Zone {
        guard circleWidth > 0 else { return .rest }
        let lower = max(0, imageOrigin - slop)
        let upper = imageOrigin + circleWidth + min(slop, titleGap)
        return (x >= lower && x < upper) ? .circle : .rest
    }
}
