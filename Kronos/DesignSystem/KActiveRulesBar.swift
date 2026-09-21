// Kronos/DesignSystem/KActiveRulesBar.swift
// One quiet row of removable chips summarising the active sort/filter rules, plus a
// trailing "Reset" text button (rev 4). The caller only mounts this view when at least
// one rule is active — there is no empty/disabled state, since an empty bar or a
// disabled Clear button is exactly what rev 4 deletes from the old toolbar.
// Usage: KActiveRulesBar(chips: [("Priority ↓", { removeSort() }), ...], onReset: {})
import SwiftUI

public struct KActiveRulesBar: View {
    public struct RuleChip: Identifiable {
        public let id: AnyHashable
        public let text: String
        public let onTap: () -> Void
        public let onRemove: () -> Void

        public init<ID: Hashable>(id: ID, text: String, onTap: @escaping () -> Void = {}, onRemove: @escaping () -> Void) {
            self.id = AnyHashable(id)
            self.text = text
            self.onTap = onTap
            self.onRemove = onRemove
        }
    }

    let chips: [RuleChip]
    let onReset: () -> Void

    public init(chips: [RuleChip], onReset: @escaping () -> Void) {
        self.chips = chips
        self.onReset = onReset
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.x2) {
                ForEach(chips) { chip in
                    KChip(chip.text, trailing: .clear, onTap: chip.onTap, onTrailingTap: chip.onRemove)
                }
                Button(String(localized: "viewoptions.reset"), action: onReset)
                    .buttonStyle(.plain)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .frame(minHeight: Metrics.minHit)
            }
        }
        .frame(height: Metrics.controlCompact)
    }
}
