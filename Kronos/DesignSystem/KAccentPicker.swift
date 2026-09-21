// Kronos/DesignSystem/KAccentPicker.swift
// Settings > Appearance: pick the app's personal accent colour. A leading "White" tile for
// the default (today's look, unchanged), the `AccentPalette` neon swatches (replaces an
// earlier set borrowed from the project palette), and a native `ColorPicker` for any custom
// colour, stored as a hex string like every other slot.
// Kept as a SEPARATE component rather than reusing KColorSwatchPicker directly, since that
// picker has no "none/default" concept and speaks `Color`, not the hex-string-or-nil the
// settings model stores.
// Usage: KAccentPicker(selectionHex: $settings.accentHex)   // Binding<String?>
import SwiftUI

public struct KAccentPicker: View {
    @Binding var selectionHex: String?
    /// Drives the native `ColorPicker`'s own selection. Seeded from `selectionHex` on
    /// appear/change so opening the picker on an already-custom accent starts on that
    /// colour instead of always resetting to white.
    @State private var customColor: Color = Tok.textPrimary
    /// The hex text field's own draft text — separate from `selectionHex` so a partial/invalid
    /// paste-in-progress never overwrites the live accent until it parses. Validated and
    /// paste-friendly by design.
    @State private var hexInput: String = ""
    @State private var hexIsInvalid = false

    public init(selectionHex: Binding<String?>) {
        self._selectionHex = selectionHex
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.x2), count: 7)

    /// True once the stored hex is neither nil nor one of the fixed swatches below — i.e. it
    /// can only have come from the custom `ColorPicker`, which is then the one that should
    /// show the ring.
    private var isCustomSelected: Bool {
        guard let hex = selectionHex else { return false }
        return !AccentPalette.swatches.contains { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            LazyVGrid(columns: columns, spacing: Space.x2) {
                swatch(name: String(localized: "accent.white", defaultValue: "White"), color: Tok.textPrimary, isSelected: selectionHex == nil) {
                    selectionHex = nil
                }
                ForEach(AccentPalette.swatches, id: \.name) { s in
                    let color = Color(hexString: s.hex)
                    swatch(name: s.name, color: color, isSelected: selectionHex?.caseInsensitiveCompare(s.hex) == .orderedSame) {
                        selectionHex = s.hex
                    }
                }
                customSwatch
            }
            hexField
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "accent.picker.title", defaultValue: "Accent colour"))
        .onAppear {
            if isCustomSelected, let hex = selectionHex {
                customColor = Color(hexString: hex)
                hexInput = hex.uppercased()
            }
        }
    }

    /// Paste-friendly hex entry alongside the swatches AND the native ColorPicker. Accepts
    /// "#RRGGBB" or "RRGGBB", case-insensitive, leading/trailing whitespace trimmed (a pasted
    /// value often carries either). A contrast floor miss is never rejected outright — unlike
    /// `ProjectPalettePrefs.replace` (identity colours must stay perceivable everywhere) the
    /// accent is one person's own choice, closer to any OS accent-colour picker: apply it and
    /// warn calmly, never silently refuse.
    private var hexField: some View {
        HStack(spacing: Space.x2) {
            KTextField("#RRGGBB", text: $hexInput, leading: "pencil")
                .frame(width: 100)
                .onChange(of: hexInput) { _, newValue in applyHexInput(newValue) }
                .uiTestAnchor("accent.hexfield")
            if hexIsInvalid {
                Text(String(localized: "accent.hex.invalid", defaultValue: "Not a valid colour"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            } else if isCustomSelected, !ContrastCheck.clearsFloor(normalizedHex(hexInput) ?? "") {
                Text(String(localized: "accent.hex.lowcontrast", defaultValue: "Hard to read on black"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
    }

    private func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, UInt32(s, radix: 16) != nil else { return nil }
        return s.uppercased()
    }

    private func applyHexInput(_ raw: String) {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hexIsInvalid = false; return }
        guard let hex = normalizedHex(raw) else { hexIsInvalid = true; return }
        hexIsInvalid = false
        selectionHex = hex
        customColor = Color(hexString: hex)
    }

    private func swatch(name: String, color: Color, isSelected: Bool, onPick: @escaping () -> Void) -> some View {
        Button(action: onPick) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .strokeBorder(Tok.textPrimary, lineWidth: isSelected ? 2 : 0)
                        .padding(-2)
                )
        }
        .buttonStyle(.plain)
        .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
        .accessibilityLabel(KProjectPalette.displayName(for: name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The custom tile: a `ColorPicker` whose own swatch face IS the tile, so there is no
    /// second control to open — clicking it opens the system colour panel directly. Before
    /// any custom colour is chosen its face is a quiet dashed ring + "+" (not a solid white
    /// fill — that read as a second, unlabelled "White" tile in the grid, indistinguishable
    /// from the real default swatch at a glance). Once a custom colour IS the active accent
    /// the tile fills with that colour, same as every other swatch.
    // ROOT CAUSE (was): the invisible `ColorPicker` was added as an `.overlay()` onto a view
    // still boxed at `.frame(width: 20, height: 20)` — the LATER `.frame(minWidth: minHit...)`
    // only grew the outer container, it could not retroactively grow the overlay already
    // anchored to that smaller box. A hit target must be sized to its FINAL frame before
    // anything is layered on top of it, never after. Net effect: a native macOS `ColorPicker`'s
    // real NSColorWell control centres and often renders smaller than even the 20x20 box it's
    // given, so the actual clickable pixels were a few points in the middle of the tile — a
    // click on the "+" almost always missed it.
    // Fix: give the `ColorPicker` the FULL `Metrics.minHit` frame + an explicit `.contentShape`
    // FIRST, then draw the visual circle as its `.background` (same size, purely decorative,
    // `allowsHitTesting(false)` so it can never steal the click) — the picker is now the
    // outermost, topmost view and its hit area is the whole visible tile, not a sliver of it.
    private var customSwatch: some View {
        ColorPicker(selection: $customColor, supportsOpacity: false) { EmptyView() }
            .labelsHidden()
            .opacity(0.015)   // invisible but still the real hit target/system panel trigger
            .frame(width: Metrics.minHit, height: Metrics.minHit)
            .contentShape(Rectangle())
            .background(customSwatchFace)
            .onChange(of: customColor) { _, newValue in selectionHex = newValue.toAccentHexString() }
            .accessibilityLabel(String(localized: "accent.custom", defaultValue: "Custom colour"))
            .accessibilityAddTraits(isCustomSelected ? [.isButton, .isSelected] : .isButton)
            .uiTestAnchor("accent.custom")
    }

    /// Purely decorative face beneath the real `ColorPicker` hit target — never receives clicks.
    private var customSwatchFace: some View {
        ZStack {
            if isCustomSelected {
                Circle().fill(customColor)
            } else {
                Circle().strokeBorder(Tok.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Icon("plus", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
            }
        }
        .frame(width: 20, height: 20)
        .overlay(
            Circle()
                .strokeBorder(Tok.textPrimary, lineWidth: isCustomSelected ? 2 : 0)
                .padding(-2)
        )
        .allowsHitTesting(false)
    }
}

private extension Color {
    /// Round-trips a `ColorPicker` selection to the "#RRGGBB"-less hex string `Accent.resolve`
    /// and every other slot in this settings model store (matches `SettingsAppearanceTab`'s
    /// own `Color.toHexString()` for the palette editor, kept local since that one is
    /// `private` to its file).
    func toAccentHexString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return String(format: "%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}
