// Kronos/DesignSystem/Contrast.swift
// Increase Contrast, decided in one place. SwiftUI reports the system setting through
// `\.colorSchemeContrast`; a snapshot run asks for the same rendering with
// `KRONOS_SNAPSHOT_CONTRAST=increased`, so the design tools can prove the IC path without touching
// the person's System Settings. Every component that has an IC variant asks `KContrast`, never the
// environment value directly.
import SwiftUI
import AppKit

public enum KContrast {
    /// A test run forced Increase Contrast on.
    public static var forced: Bool {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT_CONTRAST"] == "increased"
    }

    /// True when the view's environment, the system setting or a test run asks for Increase Contrast.
    public static func isIncreased(_ contrast: ColorSchemeContrast) -> Bool {
        contrast == .increased || forced
    }

    /// For colours resolved outside a view's environment (the text tiers): the appearance being
    /// drawn, the system setting, or a test run.
    static func isIncreased(appearance: NSAppearance) -> Bool {
        if forced || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return true }
        let match = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
        return match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastAqua
    }
}

/// WCAG 2.1 relative luminance and contrast on sRGB components in 0...1 — the same formulas
/// verify-contrast.mjs uses, so what the app picks at runtime and what the gate measures agree.
public enum KColorMath {
    public typealias RGB = (r: Double, g: Double, b: Double)

    /// The colour's sRGB components (alpha ignored).
    public static func srgb(_ color: Color) -> RGB {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    public static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    public static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static func contrastOnBlack(_ c: RGB) -> Double { contrast(luminance(c), 0) }

    /// `c` mixed toward white just enough to reach `ratio` against black.
    static func lift(_ c: RGB, toContrast ratio: Double) -> RGB {
        var t = 0.0
        var out = c
        while contrastOnBlack(out) < ratio, t < 1 {
            t = min(1, t + 0.01)
            out = (c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t)
        }
        return out
    }
}

/// White text tones that step up under Increase Contrast. The colour is resolved by AppKit at
/// draw time for the appearance it is drawn in, so turning the setting on repaints every view
/// with no re-render plumbing. Each tone is created once (a `static let` in `Tok`), so comparing
/// it with itself stays stable.
public enum KTone {
    public static func white(_ alpha: Double, increasedContrast icAlpha: Double) -> Color {
        Color(nsColor: nsWhite(alpha, increasedContrast: icAlpha))
    }

    /// The dynamic colour behind `white`, for a caller (the live test) that resolves it in a named appearance.
    static func nsWhite(_ alpha: Double, increasedContrast icAlpha: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: KContrast.isIncreased(appearance: appearance) ? icAlpha : alpha)
        }
    }
}
