// Kronos/DesignSystem/KKeyHint.swift
// Keyboard shortcut glyphs, macOS-style key caps. Usage: KKeyHint("⌘", "V").
// Each argument is ONE key on ONE cap — never pass alternatives or a range as a single
// string ("1-4", "S/M/L"): that text has no room to wrap inside a key cap's fixed height,
// so it wraps mid-word instead and breaks the row. Give each alternative its own cap
// (KKeyHint("1", "–", "4")) or use KKeyHintRow, which lays a whole legend out that way.
import SwiftUI

public struct KKeyHint: View {
    let keys: [String]
    public init(_ keys: String...) { self.keys = keys }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in KKeyCap(key) }
        }
        .accessibilityHidden(true)
    }
}

/// One key cap: fixed single-line text so it can never wrap or truncate, and a minimum
/// width equal to its height so a lone glyph ("⌘", "1") reads as a square, matching every
/// other cap in the row instead of shrinking to its own narrower text.
struct KKeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    private var capHeight: CGFloat { 16 * DSScale.text }

    var body: some View {
        Text(key)
            .font(Typo.mono)
            .foregroundStyle(Tok.textTertiary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: capHeight, minHeight: capHeight)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
    }
}

/// One hint: one or more key caps followed by their label, centred on the same line at
/// every text size. The single call site every screen should use for "press this key to
/// do that" — a legend, a footer, a flow row — so a cap is never hand-rolled as plain
/// monospaced text on a background, and prose never stands in for a cap ("Option-Return
/// for a new line" reads as a cap + label here, not as a sentence).
public struct KKeyHintItem: View {
    let keys: [String]
    let label: String
    public init(_ keys: [String], label: String) { self.keys = keys; self.label = label }

    public var body: some View {
        HStack(spacing: Space.x1) {
            HStack(spacing: 2) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KKeyCap(key) }
            }
            Text(label)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }
}

/// A legend/footer row of `KKeyHintItem`s that wraps whole items to the next line instead
/// of compressing a cap's text (see KFlowLayout).
public struct KKeyHintRow: View {
    let items: [(keys: [String], label: String)]
    public init(_ items: [(keys: [String], label: String)]) { self.items = items }

    public var body: some View {
        KFlowLayout(spacing: Space.x4, lineSpacing: Space.x2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                KKeyHintItem(item.keys, label: item.label)
            }
        }
    }
}
