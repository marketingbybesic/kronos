// Kronos/DesignSystem/KProjectGlyph.swift
// A project's identity mark: its icon (fallback: a dot) drawn in the project's colour —
// but ONLY as far as the colour mode AND Settings > Appearance's colour carriers allow. This
// is the single component in the app permitted to show project hue, and it never decides
// that itself: the tint always comes from `Chroma.tint(color, mode:isFocus:carrier:carriers:)`,
// so Focus mode shows hue on the focus task's glyph only, an OFF carrier forces that surface
// neutral even in Full/Focus, and Calm shows none — from every screen, with no per-screen code.
// `carrier:` names which of the four checkboxes (row glyph / Now card / sidebar project /
// menu-bar title) this instance is; leave it `.other` for anything not one of those four
// (chips, pickers, gallery samples) — `.other` is always allowed.
// Emoji left the UI: the `emoji` parameter of the legacy initializer is still accepted so
// existing call sites compile, but it is not rendered.
// Usage: KProjectGlyph(icon: "utensils", colorHex: "#F2994A", isFocus: isFocusTask)
//        KProjectGlyph(icon: "camera", color: tint, isFocus: true, size: Metrics.iconXL, style: .plate)
import SwiftUI

public struct KProjectGlyph: View {
    public enum Style {
        /// Just the icon / dot. Rows, chips, the sidebar.
        case bare
        /// Icon on a faint rounded plate of the same tint. Editor preview, Now card.
        case plate
    }

    let icon: String?
    let color: Color
    var isFocus: Bool
    var size: CGFloat
    var dotSize: CGFloat
    var style: Style
    var carrier: ChromaCarrier
    @Environment(\.chromaMode) private var chromaMode
    @State private var carriersWatcher = ChromaCarriersWatcher()

    public init(icon: String?, color: Color, isFocus: Bool = false,
                size: CGFloat = Metrics.iconL, dotSize: CGFloat = Metrics.projectDot, style: Style = .bare,
                carrier: ChromaCarrier = .other) {
        // nil, "" and the legacy store default "circle" all mean "no icon": draw the dot.
        self.icon = (icon == nil || icon == "" || icon == "circle") ? nil : icon
        self.color = color
        self.isFocus = isFocus
        self.size = size
        self.dotSize = dotSize
        self.style = style
        self.carrier = carrier
    }

    /// `colorHex` nil or unparsable = no colour chosen: the glyph stays neutral in every mode.
    public init(icon: String?, colorHex: String?, isFocus: Bool = false,
                size: CGFloat = Metrics.iconL, dotSize: CGFloat = Metrics.projectDot, style: Style = .bare,
                carrier: ChromaCarrier = .other) {
        self.init(icon: icon, color: colorHex.map { Color(hexString: $0) } ?? Tok.textSecondary,
                  isFocus: isFocus, size: size, dotSize: dotSize, style: style, carrier: carrier)
    }

    /// Legacy signature, kept for source compatibility. `emoji` is ignored; the mark is the
    /// dot until the call site adopts `icon:`. Still tinted through Chroma, so it obeys the
    /// colour mode.
    public init(color: Color, emoji: String? = nil, size: CGFloat = Metrics.iconL, dotSize: CGFloat = Metrics.projectDot) {
        self.init(icon: nil, color: color, isFocus: false, size: size, dotSize: dotSize, style: .bare, carrier: .other)
    }

    private var tint: Color {
        Chroma.tint(color, mode: chromaMode, isFocus: isFocus, carrier: carrier, carriers: carriersWatcher.carriers)
    }

    public var body: some View {
        ZStack {
            if style == .plate {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(tint.opacity(0.14))
            }
            if let icon {
                Icon(icon, size: style == .plate ? size * 0.62 : size)
                    .foregroundStyle(tint)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.select, value: isFocus)
        .animation(Motion.select, value: chromaMode)
        .animation(Motion.select, value: carriersWatcher.carriers)
        .accessibilityHidden(true)
    }
}
