// Kronos/Impuls/ImpulsCardView.swift — the ImpulsCard layout.
// The hero is the first move (or, when the move is only a generic placeholder, the task's own title),
// read first by design. The mentor line crossfades in place (opacity only, no layout shift) when
// ImpulsMentor swaps its `line`; the task itself never changes under this view.

import SwiftUI
import KronosCore

struct ImpulsCardView: View {
    let card: ImpulsCard
    var mentor: ImpulsMentor
    let hero: ImpulsDefaults.Hero
    /// nil when there is nothing to say beyond what the card shows.
    let leftOff: String?
    /// "Another" exists only while it can do something.
    let showsAnother: Bool
    let onStart: () -> Void
    let onAnother: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        KPanel(padding: Space.x5, radius: Radius.card, floating: true) {
            VStack(alignment: .leading, spacing: Space.x4) {
                // The card reads as ONE summary element (first move, then title, estimate, depth,
                // mentor line) for accessibility; the buttons stay separate elements.
                VStack(alignment: .leading, spacing: Space.x4) {
                    Text(hero.hero)
                        .font(Typo.title)
                        .foregroundStyle(Tok.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiTestAnchor("impuls.hero")

                    if let secondary = hero.secondary {
                        Text(secondary)
                            .font(Typo.row)
                            .foregroundStyle(Tok.textSecondary)
                            .lineLimit(2)   // two lines before truncating
                    }

                    if let leftOff { LeftOffLine(text: leftOff) }

                    metaRow

                    // An empty line means the reason was only the default ranking: nothing to say.
                    if !mentor.line.isEmpty {
                        KHairline()
                        mentorLineView
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSummaryElement)

                buttons
            }
        }
        .frame(maxWidth: Metrics.impulsCardWidth)
        .accessibilityElement(children: .contain)
    }

    // ONE Text, ONE view identity: `.contentTransition(.opacity)` is the platform primitive for a value
    // changing under one persistent Text, so there is no second view to go stale. The snapshot harness
    // captures once at a fixed delay and can catch the crossfade half-resolved, so the animation is off
    // there only (the same `KronosEnv.isSnapshot` check every hermetic path uses).
    private var mentorLineView: some View {
        Text(mentor.line)
            .font(Typo.body)
            .foregroundStyle(Tok.textSecondary)
            .frame(minHeight: Space.x8, alignment: .topLeading)
            .contentTransition(.opacity)
            .animation(KronosEnv.isSnapshot ? nil : Motion.curve(Motion.medium), value: mentor.line)
            .accessibilityLabel(mentor.line)
    }

    private var metaRow: some View {
        HStack(spacing: Space.x3) {
            if let project = card.task.project {
                HStack(spacing: Space.x1) {
                    // Impuls only ever shows the task Start is about to pin as focus, so its glyph
                    // reads `isFocus: true` exactly as KNowCard's own convention does.
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
                    .frame(height: Metrics.chipHeight)
                    .kBorder(Tok.borderControl, radius: Radius.chip)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        HStack(spacing: Space.x2) {
            // "Not now" sets the task aside for the rest of today and closes; "Another" swaps it and
            // is absent (not greyed) once it can no longer do anything.
            Button(String(localized: "impuls.button.skip"), action: onNotNow)
                .kButton(.ghost)
                .accessibilityHint(String(localized: "impuls.a11y.setaside.hint"))
                .uiTestAnchor("impuls.notnow")
            if showsAnother {
                Button(String(localized: "impuls.button.another"), action: onAnother)
                    .kButton(.secondary)
                    .accessibilityHint(String(localized: "impuls.a11y.another.hint"))
            }
            Spacer()
            Button(String(localized: "impuls.button.start"), action: onStart)
                .kButton(.primary)
                .keyboardShortcut(.defaultAction)
                .uiTestAnchor("impuls.start")
        }
    }
}
