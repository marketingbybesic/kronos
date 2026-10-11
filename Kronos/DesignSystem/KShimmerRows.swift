// Kronos/DesignSystem/KShimmerRows.swift
// The pane-level loading placeholder a list shows in place of a blank screen while its initial
// fetch is still outstanding past 250 ms (spec §4.7/§11 TaskRow "pane-level": "never per row;
// the whole list shows `EmptyState(.loading)` if a fetch exceeds 250 ms"; shimmer geometry
// borrowed from §3.2's sidebar precedent — 3 rows, `raised` fill, 0.6↔1.0 opacity, 1.2 s loop,
// suppressed under Reduce Motion where the rows render as static bars, spec §12). `raised`
// is pure black like every other OLED surface (Tokens.swift), so a quiet hairline border
// carries the shape the way every other elevation in this app does, never a grey slab.
// Usage: KShimmerRows() in place of the normal empty/row content while loading.
import SwiftUI

public struct KShimmerRows: View {
    private let count: Int
    @State private var isPulsing = false

    public init(count: Int = 3) {
        self.count = count
    }

    public var body: some View {
        VStack(spacing: Space.x1) {
            ForEach(0..<count, id: \.self) { _ in bar }
        }
        .padding(.horizontal, Space.x3)
        .padding(.vertical, Space.x2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "list.loading"))
        .onAppear {
            guard !Motion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: Motion.attentionLoop).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .fill(Tok.raised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .stroke(Tok.hairline, lineWidth: Metrics.hairline)
            )
            .frame(height: Metrics.rowHeight)
            .opacity(Motion.reduceMotion ? 1 : (isPulsing ? 1.0 : 0.6))
    }
}
