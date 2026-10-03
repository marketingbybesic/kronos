// Kronos/DesignSystem/KSelectionTint.swift
// How a selected row's fill is derived from the hue it is selected in. The hue itself is decided
// elsewhere (KronosCore `SelectionHue`: the task's project colour, else the user's accent, white
// in the monochrome mode); this only turns a hue into a fill that stays calm on #000.
// White (the white accent and the monochrome mode, both `Tok.textPrimary`) keeps the original
// neutral `Tok.selectedFill`, exactly as `KRing` keeps `Tok.focusRing` for it.
// Hover is never tinted: `Tok.hoverFill` stays a neutral plate.
import SwiftUI

enum KSelection {
    /// Fill behind a selected row. A hue is laid over #000 at `Tok.selectedTintOpacity`
    /// (`selectedTintOpacityIC` under Increase Contrast); white keeps the neutral selected fill
    /// (`selectedFillIC` under Increase Contrast). A test run's forced Increase Contrast counts
    /// too, so every caller follows `KRONOS_SNAPSHOT_CONTRAST` without reading it itself.
    static func fill(_ tint: Color, increasedContrast: Bool = false) -> Color {
        let ic = increasedContrast || KContrast.forced
        if tint == Tok.textPrimary { return ic ? Tok.selectedFillIC : Tok.selectedFill }
        return tint.opacity(ic ? Tok.selectedTintOpacityIC : Tok.selectedTintOpacity)
    }
}

/// The small leading mark of a view header (an icon, or the project's dot), drawn in a hue
/// decided by the caller. Not a project glyph: it does not consult the colour mode itself.
struct KViewMark: View {
    let icon: String?
    let tint: Color
    var size: CGFloat = Metrics.iconL
    var dotSize: CGFloat = Metrics.projectDot

    var body: some View {
        ZStack {
            if let icon, !icon.isEmpty, icon != "circle" {
                Icon(icon, size: size).foregroundStyle(tint)
            } else {
                Circle().fill(tint).frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
