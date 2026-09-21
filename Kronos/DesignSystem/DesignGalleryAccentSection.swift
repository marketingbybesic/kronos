// Kronos/DesignSystem/DesignGalleryAccentSection.swift
// Gallery section: user accent colour — every one of its six uses side by side (primary
// button, selection bar, focus ring, toggle on-state, Now card Complete ring, selected
// segment), so a single crop confirms nothing else took the colour (row title, chips, badges
// stay neutral text). This section reads `\.kAccent` from the ENVIRONMENT only — it never
// resolves its own — so `gallery-shot-main.swift`'s optional 4th argument (an accent hex) is
// what the gates (G4-G6) actually control.
//
// The KAccentPicker itself is deliberately NOT drawn on this screen: its swatches are
// always-coloured user data (like KColorSwatchPicker's), so a picker rendered here would
// fail the Calm chroma gate (G4) for the wrong reason — the same reason chroma-check.swift
// is never run against the `pickers` gallery section. The picker is exercised in the full
// DesignGallery assembly (DesignGallery.swift) instead, alongside the other pickers.
import SwiftUI

private enum GalleryAccentSegment: Hashable { case a, b }

struct DesignGalleryAccentSection: View {
    @State private var toggleOn = true
    @State private var segment: GalleryAccentSegment = .a
    @Environment(\.kAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "Accent colour — uses")
            HStack(spacing: Space.x4) {
                Button("Save view") {}.kButton(.primary)
                KToggleRow("Auto-triage", isOn: $toggleOn).fixedSize()
                KSegmented(selection: $segment, segments: [
                    .init(value: .a, text: "Deadline"),
                    .init(value: .b, text: "Quick wins"),
                ])
            }
            // A snapshot has no live keyboard event to carry, so the ring is forced on
            // directly (same pattern as DesignGalleryControlsSection's own focus demo)
            // rather than routed through real `.focused()`, which the offscreen harness
            // deliberately clears before capture (DesignGallerySnapshot.render).
            Text("Focused field").font(Typo.row).foregroundStyle(Tok.textPrimary)
                .padding(.horizontal, Space.x3).frame(width: 220, height: Metrics.controlRegular, alignment: .leading)
                .background(Tok.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .kFocusRing(true, radius: Radius.control)
            KListRow(isSelected: true, isChecked: false, accessibilityLabel: "Selected row",
                      onToggle: {}, onSelect: {}) {
                Text("Selected list row").font(Typo.row).foregroundStyle(Tok.textPrimary)
            }
            .frame(width: 260)
            KNowCard(firstMove: "Reply to the Acme intro email", title: "Follow up with Acme", remaining: 4, onComplete: {})
                .frame(width: 340)
            // The Complete ring only shows the accent mid-completion (KNowCard's own
            // private @State), which a static screenshot cannot trigger from outside —
            // shown here as the same fill+check the real card draws in that instant.
            HStack(spacing: Space.x3) {
                ZStack {
                    Circle().fill(accent)
                    CheckMark().stroke(Accent.onFill(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: Metrics.nowCardComplete * 0.4, height: Metrics.nowCardComplete * 0.4)
                }
                .frame(width: Metrics.nowCardComplete, height: Metrics.nowCardComplete)
                Text("Now card Complete ring, mid-completion").font(Typo.meta).foregroundStyle(Tok.textTertiary)
            }
        }
    }
}
