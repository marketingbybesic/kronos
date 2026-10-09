// Kronos/Settings/AgentCapMeters.swift
// Three quiet usage bars under an agent block in Settings > Agents: tasks created today against
// the daily cap, proposals waiting for review against the pending cap, and calls in the current
// minute against the rate limit. Never red: the fill just steps to the stronger neutral tone
// once a cap is reached.

import SwiftUI

struct AgentCapMeters: View {
    let row: AgentsSettingsController.Row

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            meter(used: row.createdToday, cap: row.dailyCap, label: String(format: String(localized: "agents.caps.created"), row.createdToday, row.dailyCap))
            meter(used: row.pending, cap: row.pendingCap, label: String(format: String(localized: "agents.caps.pending"), row.pending, row.pendingCap))
            meter(used: row.callsMinute, cap: row.perMinute, label: String(format: String(localized: "agents.caps.calls"), row.callsMinute, row.perMinute))
        }
        .accessibilityElement(children: .combine)
        .uiTestAnchor("settings.agents.caps." + row.slug)
    }

    private func meter(used: Int, cap: Int, label: String) -> some View {
        HStack(spacing: Space.x3) {
            Text(label)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            Spacer(minLength: Space.x3)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                    .fill(Tok.controlFill)
                RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                    .fill(used >= max(cap, 1) ? Tok.textSecondary : Tok.textTertiary)
                    .frame(width: Metrics.capMeterWidth * min(1, CGFloat(used) / CGFloat(max(cap, 1))))
            }
            .frame(width: Metrics.capMeterWidth, height: Metrics.capMeterHeight)
        }
    }
}
