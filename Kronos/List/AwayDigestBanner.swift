// Kronos/List/AwayDigestBanner.swift
// "While you were away" card above the list, same quiet hairline-bordered row as CoachBanner
// (Kronos/List/CoachBanner.swift): up to two lines of copy plus two text actions, never red,
// never modal. Reads AwayDigest.shared directly — the single source of truth — and never keeps
// its own copy; Dismiss and Review next both clear it through AwayDigest itself.
// Second line (Kronos v1.2 Phase 2 slice D3): items pending over a day, independent of whether
// `summary` itself is nil — the card surfaces on its own for a rotting queue even when the
// person was never technically "away". No new banner component: still this one card.
import SwiftUI
import KronosCore

struct AwayDigestBanner: View {
    let model: AppModel

    var body: some View {
        let s = AwayDigest.shared.summary
        let aging = AwayDigest.shared.agingCount
        if s != nil || aging > 0 {
            content(s, aging: aging)
                .padding(.horizontal, Space.x4)
                .padding(.top, Space.x3)
        }
    }

    private func content(_ s: AgentAwaySummary?, aging: Int) -> some View {
        HStack(alignment: .top, spacing: Space.x2) {
            Icon("cpu", size: Metrics.iconS)
                .foregroundStyle(Tok.textSecondary)
                .padding(.top, Space.x1)
            VStack(alignment: .leading, spacing: Space.x1) {
                if let s, !s.isEmpty {
                    Text(String(format: String(localized: "agents.digest.line"), s.finished, s.proposed))
                        .font(Typo.row)
                        .foregroundStyle(Tok.textSecondary)
                        .lineLimit(1)
                }
                if aging > 0 {
                    Text(KPlural.hr(aging, one: String(localized: "agents.digest.aging.one"),
                                    few: String(localized: "agents.digest.aging.few"),
                                    many: String(localized: "agents.digest.aging.many")))
                        .font(Typo.row)
                        .foregroundStyle(Tok.textSecondary)
                        .lineLimit(1)
                        .uiTestAnchor("list.awaydigest.aging")
                }
            }
            Spacer(minLength: Space.x2)
            Button(String(localized: "agents.digest.dismiss")) { AwayDigest.shared.dismiss() }
                .kButton(.ghost, size: .compact)
                .uiTestAnchor("list.awaydigest.dismiss")
            Button(String(localized: "agents.digest.review")) { AwayDigest.shared.openReview(model: model) }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("list.awaydigest.review")
        }
        .padding(.horizontal, Space.x3)
        .padding(.vertical, Space.x2)
        .kBorder(Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .uiTestAnchor("list.awaydigest")
    }
}
