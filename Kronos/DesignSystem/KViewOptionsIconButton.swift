// Kronos/DesignSystem/KViewOptionsIconButton.swift
// The list toolbar's ONE entry point for sort/filter/display (replaces an earlier
// five-control toolbar). Icon-only `sliders`, regular control height, a small white
// count badge (black number) at top-trailing when rules are active, no chevron — this
// is a button that opens a popover, not a menu, so it carries no dropdown affordance.
// Usage: KViewOptionsIconButton(activeCount: 2) { showPopover = true }
import SwiftUI

public struct KViewOptionsIconButton: View {
    let activeCount: Int
    let onTap: () -> Void

    public init(activeCount: Int, onTap: @escaping () -> Void) {
        self.activeCount = activeCount
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            Icon("sliders", size: Metrics.iconM)
        }
        .kButton(.icon)
        .overlay(alignment: .topTrailing) {
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Circle().fill(Tok.textPrimary))
                    .offset(x: 5, y: -5)
            }
        }
        .accessibilityLabel(String(localized: "viewoptions.title"))
        // Croatian needs one/few/many plural forms, not hardcoded English-only prose.
        .accessibilityValue(activeCount > 0 ? KPlural.hr(activeCount,
            one: String(localized: "a11y.viewoptions.activerules.one"),
            few: String(localized: "a11y.viewoptions.activerules.few"),
            many: String(localized: "a11y.viewoptions.activerules.many")) : "")
        .help(String(localized: "a11y.viewoptions.help"))
    }
}
