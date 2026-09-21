// Kronos/DesignSystem/KSegmented.swift
// Generic N-way segmented control — the shape KSidebarModeToggle and the recurrence
// anchor picker each hand-built separately. Monochrome: selected segment is a faint
// white fill, never a hue. Icon-only or text segments, caller's choice.
// Usage:
//   KSegmented(selection: $mode, segments: [
//       .init(value: .iconsOnly, icon: "panel-right", label: "Icons only"),
//       .init(value: .iconsAndText, icon: "list-ordered", label: "Icons and text"),
//   ])
//   KSegmented(selection: $anchor, segments: [
//       .init(value: .fromDueDay, text: "Due date"),
//       .init(value: .fromCompletionDay, text: "Completion date"),
//   ])
import SwiftUI

public struct KSegment<Value: Hashable> {
    public let value: Value
    public var icon: String?
    public var text: String?
    public var accessibilityLabel: String
    public var hint: String?

    /// Icon-only segment (e.g. a mode rail switch).
    public init(value: Value, icon: String, label: String) {
        self.value = value
        self.icon = icon
        self.text = nil
        self.accessibilityLabel = label
    }

    /// Text segment (e.g. a recurrence anchor picker).
    public init(value: Value, text: String) {
        self.value = value
        self.icon = nil
        self.text = text
        self.accessibilityLabel = text
    }

    /// Icon + text segment; `hint` is the tooltip (e.g. a colour mode and what it does).
    public init(value: Value, icon: String, text: String, hint: String? = nil) {
        self.value = value
        self.icon = icon
        self.text = text
        self.accessibilityLabel = text
        self.hint = hint
    }
}

public struct KSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [KSegment<Value>]
    @Environment(\.kAccent) private var accent

    public init(selection: Binding<Value>, segments: [KSegment<Value>]) {
        self._selection = selection
        self.segments = segments
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentButton(segment)
            }
        }
        .padding(2)
        .background(Tok.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func segmentButton(_ segment: KSegment<Value>) -> some View {
        let isOn = selection == segment.value
        return Button {
            withAnimation(Motion.select) { selection = segment.value }
        } label: {
            HStack(spacing: Space.x1 + 2) {
                if let icon = segment.icon {
                    Icon(icon, size: Metrics.iconM)
                }
                if let text = segment.text {
                    Text(text).font(Typo.row).lineLimit(1)
                }
            }
            .padding(.horizontal, segment.text == nil ? 0 : Space.x2)
            .frame(minWidth: Metrics.controlCompact, minHeight: Metrics.controlCompact - 4)
            // The marker fill carries the accent (feature H) at the SAME translucency as the
            // prior neutral pill (`Tok.dropFill`'s 0.12) so the default (white) accent stays
            // pixel-identical to before this feature (gate G6); the label stays plain text —
            // at this low an opacity a black/white flip would be illegible either way.
            .foregroundStyle(isOn ? Tok.textPrimary : Tok.textTertiary)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                    .fill(isOn ? accent.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
        .help(segment.hint ?? (segment.text == nil ? segment.accessibilityLabel : ""))
        .accessibilityLabel(segment.accessibilityLabel)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
