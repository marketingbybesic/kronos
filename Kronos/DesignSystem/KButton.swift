// Kronos/DesignSystem/KButton.swift
// KButtonStyle: primary / secondary / ghost / icon-only, one ButtonStyle covering hover,
// pressed, focused, disabled. The primary fill reads the user's accent colour
// (`\.kAccent`, default white) with its label flipped black/white by contrast — every
// other kind stays fully neutral; colour never appears on text/secondary/ghost/icon chrome.
// Usage:
//   Button("Save view") { }.kButton(.primary)
//   Button("Cancel") { }.kButton(.secondary)
//   Button("Clear") { }.kButton(.ghost)
//   Button { } label: { Icon("filter") }.kButton(.icon).accessibilityLabel("Filter")
import SwiftUI

public struct KButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost, icon }
    public enum Size { case compact, regular }

    let kind: Kind
    let size: Size
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.kAccent) private var accent
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    public init(_ kind: Kind, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    private var height: CGFloat { size == .compact ? Metrics.controlCompact : Metrics.controlRegular }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.rowStrong)
            .foregroundStyle(foreground(pressed: configuration.isPressed))
            .frame(height: height)
            .padding(.horizontal, kind == .icon ? 0 : Space.x3)
            .frame(minWidth: kind == .icon ? height : nil)
            .background(background(pressed: configuration.isPressed))
            // Disabled secondary/icon buttons recede fully — no border at all, so they
            // read as receded rather than "outlined but greyed."
            .kBorder(isEnabled ? borderColor : .clear, radius: Radius.control)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .kFocusRing(isFocused, radius: Radius.control)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .focusable(isEnabled, interactions: .activate)
            .focused($isFocused)
            // macOS draws its own native focus/bezel ring underneath a custom
            // ButtonStyle in some contexts, which read as a permanent "resting state
            // ring" on the primary button. This button fully owns its own focus
            // indicator via kFocusRing, so the system one is redundant and disabled.
            .focusEffectDisabled()
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.98 : 1)
            .animation(Motion.hover, value: isHovering)
            .animation(Motion.hover, value: configuration.isPressed)
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:   return accent.opacity(pressed ? 0.80 : (isHovering ? 1.0 : 0.92))
        case .secondary: return pressed ? Tok.dropFill : (isHovering ? Tok.pressedFill : Tok.controlFill)
        case .ghost:      return pressed ? Tok.pressedFill : (isHovering ? Tok.hoverFill : .clear)
        case .icon:       return pressed ? Tok.pressedFill : (isHovering ? Tok.hoverFill : .clear)
        }
    }

    private func foreground(pressed: Bool) -> Color {
        switch kind {
        case .primary:   return Accent.onFill(accent)   // black or white label, whichever reads on this fill
        case .secondary: return Tok.textPrimary
        // Style G: a text button is text. It wakes to primary under the pointer.
        case .ghost:     return isHovering || pressed ? Tok.textPrimary : Tok.textSecondary
        case .icon:      return isHovering || pressed ? Tok.textPrimary : Tok.textTertiary
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary:   return .clear
        case .secondary: return .clear   // style G: a faint plate, not an outlined box
        case .ghost, .icon: return .clear
        }
    }
}

public extension View {
    /// Convenience: `.kButton(.primary)` == `.buttonStyle(KButtonStyle(.primary))`.
    func kButton(_ kind: KButtonStyle.Kind, size: KButtonStyle.Size = .regular) -> some View {
        buttonStyle(KButtonStyle(kind, size: size))
    }
}
