// Kronos/DesignSystem/ProjectPalettePrefs.swift
// Project palette editor (rename-free): reorder + replace a swatch with a custom colour,
// contrast-checked against black before it is accepted. `KProjectPalette.swatches`
// (Kronos/DesignSystem/KColorSwatchPicker.swift) is the design system's fixed 12-swatch source
// of truth and its literal entries are never edited — so the editor stores an ORDERING of the
// same 12 base swatches plus an optional custom hex override per slot.
// `KProjectPalette.orderedSwatches` (below) reads this ordering directly, so EVERY picker in
// the app (KColorSwatchPicker, KAccentPicker's project swatches) reflects a reorder/replace
// immediately, not just the Settings tab that edits it.
import SwiftUI

/// One palette slot: the base swatch it started as, and an optional custom colour that has
/// replaced it (nil = still the original swatch).
struct PaletteSlot: Codable, Equatable, Identifiable {
    var id: String { baseName }
    let baseName: String
    var customHex: String?

    /// The hex this slot actually shows: the custom override if set and still valid, else the
    /// base swatch's own hex.
    func resolvedHex(baseHex: String) -> String { customHex ?? baseHex }
}

enum ProjectPalettePrefs {
    private static let key = "kronos.appearance.paletteOrder"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .snapshotScratch : .standard
    }

    /// The 12 base swatches in the user's chosen order, each with its override (if any).
    /// Falls back to `KProjectPalette.swatches`' own order with no overrides — pixel-identical
    /// to today until the palette is reordered or replaced.
    static var slots: [PaletteSlot] {
        get {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([PaletteSlot].self, from: data) else {
                return KProjectPalette.swatches.map { PaletteSlot(baseName: $0.name, customHex: nil) }
            }
            // A slot for a swatch the design system no longer has (or a freshly added one
            // this saved order predates) is dropped/added rather than crashing the editor.
            let known = Set(KProjectPalette.swatches.map(\.name))
            var kept = decoded.filter { known.contains($0.baseName) }
            let keptNames = Set(kept.map(\.baseName))
            for swatch in KProjectPalette.swatches where !keptNames.contains(swatch.name) {
                kept.append(PaletteSlot(baseName: swatch.name, customHex: nil))
            }
            return kept
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: key)
        }
    }

    static func move(fromOffsets: IndexSet, toOffset: Int) {
        var s = slots
        s.move(fromOffsets: fromOffsets, toOffset: toOffset)
        slots = s
    }

    /// Replaces `slot`'s colour with `hex` when it clears the same >= 3:1-against-black floor
    /// `verify-contrast.mjs` holds every palette swatch to, and is not red/red-adjacent: no
    /// alarm colour anywhere. Returns false (no write) when it does not clear either check, so
    /// the caller can show the calm rejection inline rather than silently no-op'ing.
    @discardableResult
    static func replace(_ slotID: String, withHex hex: String) -> Bool {
        guard ContrastCheck.clearsFloor(hex) else { return false }
        var s = slots
        guard let i = s.firstIndex(where: { $0.id == slotID }) else { return false }
        s[i].customHex = hex
        slots = s
        return true
    }

    static func resetToDefault(_ slotID: String) {
        var s = slots
        guard let i = s.firstIndex(where: { $0.id == slotID }) else { return }
        s[i].customHex = nil
        slots = s
    }
}

/// Same WCAG formula and floor as `Kronos/DesignSystem/verify-contrast.mjs` ("project-colour
/// swatch (dot/fill) >= 3:1 against pure black, no red/red-adjacent hue") — kept in sync by
/// hand since the gate script parses Swift source text and cannot import this module's logic.
enum ContrastCheck {
    static func clearsFloor(_ hexString: String) -> Bool {
        guard let (r, g, b) = rgb(hexString) else { return false }
        return contrastVsBlack(r, g, b) >= 3 && !isRed(r, g, b)
    }

    private static func rgb(_ hexString: String) -> (Double, Double, Double)? {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    private static func contrastVsBlack(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let lum = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return (lum + 0.05) / 0.05
    }

    private static func isRed(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        let maxV = max(r, g, b), minV = min(r, g, b), d = maxV - minV
        guard d > 0 else { return false }
        var h: Double
        if maxV == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxV == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return h < 20 || h > 340
    }
}

private extension UserDefaults {
    static let snapshotScratch = UserDefaults(suiteName: "kronos.snapshot.palette." + UUID().uuidString) ?? .standard
}
