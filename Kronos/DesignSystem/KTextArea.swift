// Kronos/DesignSystem/KTextArea.swift
// Multi-line notes editor with a visible hairline border — never a flat grey block.
// Usage: KTextArea("Notes…", text: $notes, minHeight: 120)
import SwiftUI

public struct KTextArea: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(_ placeholder: String, text: Binding<String>, minHeight: CGFloat = 120) {
        self.placeholder = placeholder
        self._text = text
        self.minHeight = minHeight
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Typo.body)
                    .foregroundStyle(Tok.textDisabled)
                    .padding(.horizontal, Space.x4)   // matches TextEditor's own inset + its internal text container padding
                    .padding(.vertical, Space.x3)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(Typo.body)
                .foregroundStyle(Tok.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Space.x2)
                .padding(.vertical, Space.x2)
                .focused($isFocused)
        }
        .frame(minHeight: minHeight)
        .background(Tok.bg)
        .kBorder(isFocused ? Tok.borderActive : Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Motion.hover, value: isFocused)
    }
}
