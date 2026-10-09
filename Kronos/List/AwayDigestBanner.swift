// Kronos/List/AwayDigestBanner.swift
// "While you were away" card above the list, same quiet hairline-bordered row as CoachBanner
// (Kronos/List/CoachBanner.swift): one line of copy plus two text actions, never red, never
// modal. Reads AwayDigest.shared.summary — the single source of truth — and never keeps its own
// copy; Dismiss and Review next both clear it through AwayDigest itself.
import SwiftUI
import KronosCore

struct AwayDigestBanner: View {
    let model: AppModel

    var body: some View {
        if let s = AwayDigest.shared.summary, !s.isEmpty {
            content(s)
                .padding(.horizontal, Space.x4)
                .padding(.top, Space.x3)
        }
    }

    private func content(_ s: AgentAwaySummary) -> some View {
        HStack(spacing: Space.x2) {
            Icon("cpu", size: Metrics.iconS)
                .foregroundStyle(Tok.textSecondary)
            Text(String(format: String(localized: "agents.digest.line"), s.finished, s.proposed))
                .font(Typo.row)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Space.x2)
            Button(String(localized: "agents.digest.dismiss")) { AwayDigest.shared.dismiss() }
                .kButton(.ghost, size: .compact)
                .uiTestAnchor("list.awaydigest.dismiss")
            Button(String(localized: "agents.digest.review")) { AwayDigest.shared.openReview(model: model) }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("list.awaydigest.review")
        }
        .padding(.horizontal, Space.x3)
        .frame(height: Metrics.controlRegular)
        .kBorder(Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .uiTestAnchor("list.awaydigest")
    }
}
