// Kronos/DesignSystem/KMenuBarOrdoLabel.swift
// What sits in the macOS menu bar for Ordo: a small monochrome glyph + truncated task
// title. Renders as a template image so it tints correctly for light/dark menu bars —
// no colour, matching the rest of menu-bar-extra conventions on macOS.
// Usage: KMenuBarOrdoLabel(title: task.firstMove)
import SwiftUI

public struct KMenuBarOrdoLabel: View {
    let title: String?     // nil = queue empty
    static let maxChars = 28

    public init(title: String?) {
        self.title = title
    }

    private var truncated: String {
        guard let title else { return String(localized: "ordo.title") }
        if title.count <= Self.maxChars { return title }
        return String(title.prefix(Self.maxChars - 1)) + "…"
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "list.bullet.circle")
                .font(.system(size: 13))
            Text(truncated)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "menubar.ordo.accessibility"), title ?? String(localized: "bar.empty")))
    }
}
