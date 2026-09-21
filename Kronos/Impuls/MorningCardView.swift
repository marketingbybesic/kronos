// Kronos/Impuls/MorningCardView.swift — the morning plan.
// Three proposals, max one deep, each a title + first move. In the real app this is an
// inline dismissible card at the top of Today; here it is Impuls' second Mode, kept as one
// screen with the host deciding where it is placed.

import SwiftUI
import KronosCore

struct MorningCardView: View {
    let candidates: [(task: KTask, firstMove: String)]
    let language: Lang
    let energy: KEnergyLevel
    let onAccept: () -> Void
    let onDismiss: () -> Void
    var onSwap: (Int) -> Void = { _ in }

    var body: some View {
        KPanel(padding: Space.x5, radius: Radius.card) {
            VStack(alignment: .leading, spacing: Space.x4) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(String(localized: "morning.title"))
                        .font(Typo.heading)
                        .foregroundStyle(Tok.textPrimary)
                    Text(String(localized: "morning.subtitle"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }

                VStack(spacing: Space.x3) {
                    ForEach(Array(candidates.enumerated()), id: \.element.task.id) { index, entry in
                        row(for: entry, index: index)
                    }
                }

                HStack {
                    Button(String(localized: "morning.dismiss"), action: onDismiss)
                        .kButton(.ghost)
                    Spacer()
                    Button(String(localized: "morning.accept"), action: onAccept)
                        .kButton(.primary)
                        .disabled(candidates.isEmpty)
                }
            }
        }
        .frame(maxWidth: 480)
        .accessibilityElement(children: .contain)
    }

    private func row(for entry: (task: KTask, firstMove: String), index: Int) -> some View {
        KPanel(padding: Space.x3, radius: Radius.control) {
            HStack(alignment: .top, spacing: Space.x2) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(entry.firstMove)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Tok.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.task.title)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Swaps THIS slot for the next unshown candidate in the ranking (spec
                // §7.4's Swap action) — it never re-ranks, never writes to the store, and
                // never touches the other two slots. `morning.swap` ("Swap"/"Zamijeni")
                // already exists in the catalog; reused for both the VoiceOver label and
                // the pointer tooltip so the two never drift apart.
                Button { onSwap(index) } label: { Icon("repeat", size: Metrics.iconS) }
                    .kButton(.icon)
                    .accessibilityLabel(String(localized: "morning.swap"))
                    .help(String(localized: "morning.swap"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
