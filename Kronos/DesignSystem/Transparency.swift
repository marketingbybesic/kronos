// Kronos/DesignSystem/Transparency.swift
// Reduce Transparency, decided in one place — the same precedent as `Motion.reduceMotion`
// (Tokens.swift:324-326) and `KContrast` (Contrast.swift). Any component that draws
// `.ultraThinMaterial` (currently only `GroupHeader`'s sticky background) asks
// `KTransparency.isReduced`, never the system setting directly, and falls back to an opaque
// `Tok.bg` fill with no material at all — spec §12: "Reduce Transparency: `.ultraThinMaterial`
// behind group headers and the Bar is replaced with an opaque `Tok.bg` fill."
import SwiftUI
import AppKit

public enum KTransparency {
    /// A test run forced Reduce Transparency on, so a hermetic snapshot can prove the opaque
    /// path without touching the person's System Settings.
    public static var forced: Bool {
        ProcessInfo.processInfo.environment["KRONOS_REDUCE_TRANSPARENCY"] == "1"
    }

    /// True when the system setting or a test run asks for Reduce Transparency. Re-read each
    /// call — it can change live.
    public static var isReduced: Bool {
        forced || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}
