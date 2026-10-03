// Kronos/DesignSystem/KHitTarget.swift
// The 24 pt minimum hit area for a text-only `.buttonStyle(.plain)` button. A plain button is
// pressable only on its label's opaque pixels, and its accessibility frame is the label's frame,
// so the minimum has to be put INSIDE the label (a `.frame` chained after `.buttonStyle(.plain)`
// is a wrapper around the finished button and changes neither).
// Usage: Button { ... } label: { Text("Unlink").kHitTarget() }.buttonStyle(.plain)
import SwiftUI

public extension View {
    func kHitTarget(alignment: Alignment = .leading) -> some View {
        frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit, alignment: alignment)
            .contentShape(Rectangle())
    }
}
