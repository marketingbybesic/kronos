// Kronos/Impuls/ImpulsCardView.swift — the ImpulsCard layout.
// First move is the hero line — largest type on the card, read first by design.
// The mentor line crossfades in place (opacity only, no layout shift) when ImpulsMentor
// swaps its `line`; the task itself never changes under this view.

import SwiftUI
import KronosCore

struct ImpulsCardView: View {
    let card: ImpulsCard
    var mentor: ImpulsMentor
    let canAskAnother: Bool
    let onStart: () -> Void
    let onAnother: () -> Void
    let onSkip: () -> Void

    private var language: Lang { Lang(rawValue: KronosLocale.languageCode) ?? .en }

    var body: some View {
        KPanel(padding: Space.x5, radius: Radius.card) {
            VStack(alignment: .leading, spacing: Space.x4) {
                // The card reads as ONE summary element (first move, then title, estimate,
                // depth, mentor line) for accessibility; the three buttons stay separate
                // elements, so only this group is combined.
                VStack(alignment: .leading, spacing: Space.x4) {
                    Text(ImpulsQuery.firstMove(for: card.task, language: language))
                        .font(Typo.title)
                        .foregroundStyle(Tok.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(card.task.title)
                        .font(Typo.row)
                        .foregroundStyle(Tok.textSecondary)
                        .lineLimit(1)

                    metaRow

                    KHairline()

                    mentorLineView
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSummaryElement)

                buttons
            }
        }
        .frame(maxWidth: 480)
        .accessibilityElement(children: .contain)
    }

    // ONE Text, ONE view identity, no manual two-layer trick: earlier attempts (a VStack
    // with `.id()` + `.transition()`, then a hand-rolled ZStack with a timed-out "outgoing"
    // layer) both left a stale line visibly composited under the new one in this leaf's own
    // snapshot — a `.transition` animates 0->1 on insertion regardless of a constant
    // `.opacity(0)` on the same view, and a wall-clock `sleep` to hide the old layer races
    // the harness's fixed capture delay. `.contentTransition(.opacity)` is the platform
    // primitive for exactly this (a value changing under one persistent Text), so there is
    // no second view to ever go stale or get caught mid-removal.
    /// The snapshot harness (`gate-shots.mjs`) always fires a single fixed-delay capture
    /// (`SnapshotHarness`'s 0.8 s timer) via `NSHostingView.cacheDisplay`, a synchronous
    /// redraw rather than a video frame grab. When this card's mentor-line crossfade is
    /// still resolving right around that instant (the fixture AI reply lands at the spec's
    /// 600 ms floor, `Motion.medium` runs another ~180 ms), `cacheDisplay` can catch the
    /// outgoing and incoming glyph runs on two Core Animation layers that have not yet been
    /// torn down, and composite both into one garbled frame — reproduced identically across
    /// three different transition mechanisms (`.transition`, a manual opacity ZStack,
    /// `.contentTransition` with and without `.drawingGroup()`) before finding the actual
    /// cause. Disabling the animation only inside the harness (the same `KRONOS_SNAPSHOT`
    /// check `AppModel.isHermetic` already uses) makes every snapshot deterministic and
    /// fully settled; the real running app keeps the animated crossfade untouched.
    private static var isSnapshotHarness: Bool {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
    }

    private var mentorLineView: some View {
        Text(mentor.line)
            .font(Typo.body)
            .foregroundStyle(Tok.textSecondary)
            .frame(minHeight: 34, alignment: .topLeading)
            .contentTransition(.opacity)
            .animation(Self.isSnapshotHarness ? nil : Motion.curve(Motion.medium), value: mentor.line)
            .accessibilityLabel(mentor.line)
    }

    private var metaRow: some View {
        HStack(spacing: Space.x3) {
            if let project = card.task.project {
                HStack(spacing: Space.x1) {
                    // Impuls only ever shows the task Start is about to pin as focus (ledger
                    // G8), so its glyph reads `isFocus: true` here exactly as KNowCard's own
                    // convention does for the same reason.
                    KProjectGlyph(icon: project.icon, colorHex: project.colorHex, isFocus: true, size: Metrics.iconS)
                    Text(project.name).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                }
            }
            if let minutes = card.task.estimateMinutes {
                Text(String(format: String(localized: "nowcard.estimate"), "\(minutes)"))
                    .font(Typo.meta).foregroundStyle(Tok.textTertiary)
            }
            if card.task.depth != .unknown {
                Text(card.task.depth == .shallow ? String(localized: "depth.shallow") : String(localized: "depth.deep"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .padding(.horizontal, Space.x2)
                    .frame(height: 18)
                    .kBorder(Tok.borderControl, radius: Radius.chip)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        HStack(spacing: Space.x2) {
            Button(String(localized: "impuls.button.skip"), action: onSkip)
                .kButton(.ghost)
            if canAskAnother {
                Button(String(localized: "impuls.button.another"), action: onAnother)
                    .kButton(.secondary)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)).animation(Motion.curve(Motion.fast)))
            }
            Spacer()
            Button(String(localized: "impuls.button.start"), action: onStart)
                .kButton(.primary)
                .keyboardShortcut(.defaultAction)
                // A VoiceOver hint here ("Sends this task to the top of the list") has no
                // localized key in the catalog, so the sentence is not hard-coded here — the
                // label "Start" already reads correctly without it.
        }
        .animation(Motion.curve(Motion.fast), value: canAskAnother)
    }
}
