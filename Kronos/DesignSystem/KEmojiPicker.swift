// Kronos/DesignSystem/KEmojiPicker.swift
// Compact emoji picker for project/area identity: a curated grid grouped by theme, a
// field to type/paste any emoji directly, and a button to the system character palette
// for anything not in the curated set.
// Usage: KEmojiPicker(selected: $projectEmoji)
import SwiftUI
import AppKit

public enum KEmojiCatalog {
    public static let groups: [(name: String, emoji: [String])] = [
        ("Work",    ["💼", "📁", "📊", "🗂️", "📈", "🧾", "🖥️", "⚙️"]),
        ("Life",    ["🏠", "❤️", "🌱", "🧘", "🍎", "🛒", "🚗", "✈️"]),
        ("Creative",["🎨", "📷", "🎬", "🎵", "✏️", "📚", "💡", "🧩"]),
        ("Growth",  ["🎯", "🚀", "🎓", "🏆", "🔥", "⭐", "🌟", "🧠"]),
    ]
}

public struct KEmojiPicker: View {
    @Binding var selected: String
    @State private var customText: String = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.x1), count: 8)

    public init(selected: Binding<String>) {
        self._selected = selected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            // Fixed-height scrollable viewport (~4 rows) rather than laying out every
            // group unbounded — a picker embedded in a popover must not grow the
            // popover to the full catalog's height.
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x3) {
                    ForEach(KEmojiCatalog.groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: Space.x1) {
                            Text(group.name)
                                .font(Typo.meta)
                                .foregroundStyle(Tok.textTertiary)
                            LazyVGrid(columns: columns, spacing: Space.x1) {
                                ForEach(group.emoji, id: \.self) { emoji in
                                    emojiCell(emoji)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: Metrics.pickerViewportHeight)
            // GAP (reported): no catalog key for this placeholder or the character-
            // palette button's accessibility label — left as English.
            HStack(spacing: Space.x2) {
                KTextField("Type or paste an emoji", text: $customText)
                    .frame(width: 200)
                    .onChange(of: customText) { _, newValue in
                        if let first = newValue.first { selected = String(first) }
                    }
                Button {
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Icon("sparkles", size: Metrics.iconM)
                }
                .kButton(.icon)
                .accessibilityLabel(String(localized: "a11y.emojipicker.systempicker"))
            }
        }
    }

    private func emojiCell(_ emoji: String) -> some View {
        let isOn = emoji == selected
        return Button {
            selected = emoji
        } label: {
            Text(emoji)
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isOn ? Color.white.opacity(0.10) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(isOn ? Tok.borderActive : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: String(localized: "a11y.emojipicker.emoji"), emoji))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
