// Kronos/DesignSystem/KTextField.swift
// Single-line field with an optional leading icon, hairline border, focus ring.
// Usage: KTextField("Search", text: $query, leading: "search")
import SwiftUI

public struct KTextField: View {
    let placeholder: String
    @Binding var text: String
    var leading: String?
    /// Claims first responder right after appearing (sidebar "+" rows: the name field should
    /// be ready for typing the instant the row appears, no extra click). Off by default —
    /// every other call site keeps today's behaviour unchanged.
    var autofocus: Bool = false
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(_ placeholder: String, text: Binding<String>, leading: String? = nil, autofocus: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.leading = leading
        self.autofocus = autofocus
    }

    public var body: some View {
        HStack(spacing: Space.x2) {
            if let leading {
                Icon(leading, size: Metrics.iconM)
                    .foregroundStyle(Tok.textTertiary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Tok.textPrimary)
                .focused($isFocused)
                .onAppear {
                    guard autofocus else { return }
                    // A tick's delay: a view only gets focus once it is actually in the
                    // hierarchy, so this must not fire in the same pass as appearing.
                    DispatchQueue.main.async { isFocused = true }
                }
        }
        .padding(.horizontal, Space.x3)
        .frame(height: Metrics.controlRegular)
        .background(isFocused ? Tok.bg : Tok.controlFill)
        // Style G: a faint plate at rest; the edge appears with focus (3.9:1 on its own), so the
        // field needs no second, outer ring.
        .kBorder(isFocused ? Tok.borderActive : Color.clear, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Motion.hover, value: isFocused)
    }
}
