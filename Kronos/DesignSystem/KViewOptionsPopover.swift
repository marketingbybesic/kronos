// Kronos/DesignSystem/KViewOptionsPopover.swift
// The one popover behind KViewOptionsIconButton (rev 4): three titled sections — Sort,
// Filter, Display — each separated by a hairline, ~360pt wide, OLED black, hairline
// border. This is a layout shell: the caller supplies each section's content (its own
// KSortBuilder / KFilterBuilder / display controls), so the popover carries no
// sort/filter logic itself, matching "no sorting/filtering code in views."
// Usage:
//   KViewOptionsPopover {
//       KSortBuilder(...)
//   } filter: {
//       KFilterBuilder(...)
//   } display: {
//       KToggleRow(...); Button("Save as view…") { }
//   }
import SwiftUI

public struct KViewOptionsPopover<Sort: View, Filter: View, Display: View>: View {
    @ViewBuilder let sort: () -> Sort
    @ViewBuilder let filter: () -> Filter
    @ViewBuilder let display: () -> Display

    public init(@ViewBuilder sort: @escaping () -> Sort, @ViewBuilder filter: @escaping () -> Filter,
                @ViewBuilder display: @escaping () -> Display) {
        self.sort = sort
        self.filter = filter
        self.display = display
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section(title: String(localized: "viewoptions.section.sort"), content: sort)
            KHairline()
            section(title: String(localized: "viewoptions.section.filter"), content: filter)
            KHairline()
            section(title: String(localized: "viewoptions.section.display"), content: display)
        }
        .frame(width: Metrics.popoverWidth)
        .background(Tok.overlay)
        .kBorder(Tok.hairline, radius: Radius.popover)
        .clipShape(RoundedRectangle(cornerRadius: Radius.popover, style: .continuous))
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(title)
                .font(Typo.sectionHdr)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Tok.textTertiary)
            content()
        }
        .padding(Space.x4)
    }
}

/// A single labelled toggle row for the Display section ("Show completed").
public struct KToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var isDisabled: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.kAccent) private var accent

    public init(_ label: String, isOn: Binding<Bool>, isDisabled: Bool = false) {
        self.label = label
        self._isOn = isOn
        self.isDisabled = isDisabled
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(Typo.row).foregroundStyle(isEnabled && !isDisabled ? Tok.textPrimary : Tok.textDisabled)
        }
        .toggleStyle(.switch)
        .tint(accent)   // on-state colour (feature H); default white matches the prior look exactly
        .frame(height: Metrics.controlRegular)
        .disabled(isDisabled)
        // Monochrome, matching KButtonStyle's own disabled recede — no colour change,
        // the switch itself just dims rather than greying to a tinted grey.
        .opacity(isEnabled && !isDisabled ? 1 : 0.4)
    }
}
