// Kronos/DesignSystem/DesignGalleryControlsSection.swift
// Gallery section: buttons, fields, chips/badges/panels, empty state.
import SwiftUI

private enum GallerySegmentSample: Hashable { case a, b, c }

struct DesignGalleryControlsSection: View {
    @State private var text1 = ""
    @State private var text2 = "September carousel for Acme"
    @State private var notes = ""
    @State private var checked1 = false
    @State private var checked2 = true
    @State private var segmentSample: GallerySegmentSample = .a
    @State private var toggleOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x8) {
            buttonSection
            fieldSection
            chipSection
            segmentedSection
            miscSection
        }
    }

    private var segmentedSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            GallerySectionTitle(title: "Segmented control, toggles")
            HStack(spacing: Space.x6) {
                KSegmented(selection: $segmentSample, segments: [
                    .init(value: .a, icon: "panel-right", label: "Icons only"),
                    .init(value: .b, icon: "list-ordered", label: "Icons and text"),
                ])
                KSegmented(selection: $segmentSample, segments: [
                    .init(value: .a, text: "Due date"),
                    .init(value: .b, text: "Completion date"),
                    .init(value: .c, text: "Custom"),
                ])
            }
            VStack(alignment: .leading, spacing: Space.x2) {
                KToggleRow("Show completed", isOn: $toggleOn)
                KToggleRow("Disabled toggle", isOn: .constant(false), isDisabled: true)
            }
        }
    }

    private var buttonSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            GallerySectionTitle(title: "Buttons")
            HStack(spacing: Space.x3) {
                Button("Save view") {}.kButton(.primary)
                Button("Cancel") {}.kButton(.secondary)
                Button("Clear") {}.kButton(.ghost)
                Button { } label: { Icon("filter", size: Metrics.iconM) }
                    .kButton(.icon).accessibilityLabel("Filter")
                Button("Disabled") {}.kButton(.secondary).disabled(true)
                Button("Compact") {}.kButton(.secondary, size: .compact)
            }
            // Rows never draw a focus ring for isSelected — only real keyboard focus
            // does, and only on buttons/fields. Shown here as a static, honestly
            // labelled sample since a screenshot cannot carry a live focus event.
            VStack(alignment: .leading, spacing: Space.x1) {
                Text("Keyboard focus (buttons/fields only — never from selection)").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                Text("Cancel").font(Typo.rowStrong).foregroundStyle(Tok.textPrimary)
                    .padding(.horizontal, Space.x4).frame(height: Metrics.controlRegular)
                    .background(Color.white.opacity(0.04))
                    .kBorder(Tok.borderControl, radius: Radius.control)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .kFocusRing(true, radius: Radius.control)
            }
        }
    }

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            GallerySectionTitle(title: "Fields")
            HStack(alignment: .top, spacing: Space.x4) {
                VStack(alignment: .leading, spacing: Space.x3) {
                    KTextField("Search", text: $text1, leading: "search").frame(width: 260)
                    KTextField("Task title", text: $text2).frame(width: 260)
                    HStack(spacing: Space.x4) {
                        KCheckbox(isChecked: checked1) { checked1.toggle() }
                        KCheckbox(isChecked: checked2) { checked2.toggle() }
                        Text("Mama mia").font(Typo.row).foregroundStyle(Tok.textPrimary)
                    }
                }
                KTextArea("Notes…", text: $notes, minHeight: 90).frame(width: 360)
            }
        }
    }

    private var chipSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            GallerySectionTitle(title: "Chips, badges, panels")
            HStack(spacing: Space.x2) {
                KChip("Status is Todo", trailing: .clear)
                KChip("Priority", trailing: .chevron)
                KBadge("3")
                KDeadlineLabel(text: "Today", carryDays: 3)
                KKeyHint("⌥", "V")
            }
            // KChip's leading glyph slot (defect fix): the quick-add panel had to
            // float a project dot / priority bars OUTSIDE the chip before this existed.
            // Neutral grey glyph here on purpose: this crop is measured for zero
            // colour (spec G5) — the sidebar/pickers crops are the only ones allowed
            // to show project colour.
            HStack(spacing: Space.x2) {
                KChip("Acme", trailing: .clear) {
                    KProjectGlyph(color: Tok.textDisabled, emoji: nil, size: Metrics.iconS)
                }
                KChip("High", trailing: .none) {
                    KPriorityIndicator(level: 3, of: 4, label: "High", size: Metrics.iconS)
                }
                KChip("M", trailing: .none) {
                    KEffortIndicator(level: 3, of: 5, label: nil, showLabel: false)
                }
                KChip("Deadline", trailing: .none) {
                    KDeadlineLabel(text: "2d")
                }
            }
            // Panel aligns to the SAME leading edge as every other block in this
            // section (spec B2) — no extra indent, no width constraint of its own.
            KPanel(padding: Metrics.panelPadding) {
                VStack(alignment: .leading, spacing: Space.x2) {
                    HStack {
                        Icon("sparkles", size: Metrics.iconS).foregroundStyle(Tok.textSecondary)
                        Text("Triaged").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    }
                    Text("Small and shallow; it fits the energy you said you have.")
                        .font(Typo.meta).foregroundStyle(Tok.textSecondary)
                }
            }
        }
    }

    private var miscSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            GallerySectionTitle(title: "Empty state")
            KEmptyState(icon: "inbox", title: "Nothing waiting for a home.", message: "Everything is filed.")
        }
    }
}
