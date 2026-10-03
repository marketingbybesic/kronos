// Kronos/DesignSystem/KSegmented.swift
// Generic N-way segmented control: the ONE selected-state look for a set of closely related
// choices (density, text size, energy, a popover's view switch, time-block tabs). List-like
// items use the other look (selection fill + leading bar); nothing else draws a "selected" state.
// Selected segment = a marker plate in the accent at `Tok.markerTintOpacity` plus a 1 pt edge
// (`Tok.borderActive` for the white accent, the accent at ring opacity for a hue), label
// primary; the others are tertiary on the shared track. Each segment is a real control: at least
// `Metrics.minHit` tall, keyboard-focusable with the Kronos focus ring, labelled for VoiceOver.
// Styles: `.compact` hugs its content (settings rows, popover switches); `.fill` stretches every
// segment to an equal share of the offered width (energy picker, time-block tabs).
// Usage:
//   KSegmented(selection: $mode, segments: [
//       .init(value: .iconsOnly, icon: "panel-right", label: "Icons only"),
//       .init(value: .iconsAndText, icon: "list-ordered", label: "Icons and text"),
//   ])
//   KSegmented(selection: $energy, segments: [
//       .init(value: .low, text: "Low"), .init(value: .mid, text: "Mid"), .init(value: .high, text: "High"),
//   ], style: .fill)
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

public enum KSegmentedStyle {
    /// Segments hug their content.
    case compact
    /// Every segment takes an equal share of the offered width.
    case fill
}

public struct KSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [KSegment<Value>]
    var style: KSegmentedStyle

    public init(selection: Binding<Value>, segments: [KSegment<Value>], style: KSegmentedStyle = .compact) {
        self._selection = selection
        self.segments = segments
        self.style = style
    }

    public var body: some View {
        HStack(spacing: Space.x1 / 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                KSegmentButton(segment: segment, isOn: selection == segment.value, fills: style == .fill) {
                    withAnimation(Motion.select) { selection = segment.value }
                }
            }
        }
        .padding(Space.x1 / 2)
        .frame(maxWidth: style == .fill ? .infinity : nil)
        .background(Tok.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// One segment: a plain button whose label carries its own hit area, marker and focus ring.
private struct KSegmentButton<Value: Hashable>: View {
    let segment: KSegment<Value>
    let isOn: Bool
    let fills: Bool
    let action: () -> Void
    @Environment(\.kAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    private var markerRadius: CGFloat { Radius.control - Space.x1 / 2 }

    /// The selected marker's edge: a boundary that reads on its own (>= 3:1), in the accent's hue.
    private var markerEdge: Color {
        accent == Tok.textPrimary ? Tok.borderActive : KRing.color(accent, increasedContrast: KContrast.isIncreased(contrast))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.x1 + Space.x1 / 2) {
                if let icon = segment.icon {
                    Icon(icon, size: Metrics.iconM)
                }
                if let text = segment.text {
                    Text(text).font(Typo.row).lineLimit(1)
                }
            }
            .padding(.horizontal, segment.text == nil ? 0 : Space.x2)
            // Never under the Kronos hit minimum, also at compact density.
            .frame(minWidth: max(Metrics.controlCompact, Metrics.minHit),
                   maxWidth: fills ? .infinity : nil,
                   minHeight: max(Metrics.controlCompact - Space.x1, Metrics.minHit))
            .foregroundStyle(isOn ? Tok.textPrimary : Tok.textTertiary)
            .background(
                RoundedRectangle(cornerRadius: markerRadius, style: .continuous)
                    .fill(isOn ? accent.opacity(Tok.markerTintOpacity) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: markerRadius, style: .continuous)
                    .strokeBorder(isOn ? markerEdge : .clear, lineWidth: Metrics.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kFocusRing(isFocused, radius: markerRadius)
        .focusable(true, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .help(segment.hint ?? (segment.text == nil ? segment.accessibilityLabel : ""))
        .accessibilityLabel(segment.accessibilityLabel)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
