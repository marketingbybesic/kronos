// Kronos/DesignSystem/KChromaModeSwitch.swift
// The three colour modes as one segmented control: Focus / Full / Calm, each with an icon
// and a tooltip saying what the mode does. Icon-only by default (sidebar footer); pass
// `showsLabels: true` where there is room (Settings). Internal, not public: `ChromaMode`
// is a frozen internal contract type.
// Usage: KChromaModeSwitch(mode: $model.chromaMode)
import SwiftUI

struct KChromaModeSwitch: View {
    @Binding var mode: ChromaMode
    var showsLabels: Bool

    init(mode: Binding<ChromaMode>, showsLabels: Bool = false) {
        self._mode = mode
        self.showsLabels = showsLabels
    }

    var body: some View {
        KSegmented(selection: $mode, segments: ChromaMode.allCases.map { segment(for: $0) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "chroma.mode.title", defaultValue: "Colour mode"))
    }

    private func segment(for mode: ChromaMode) -> KSegment<ChromaMode> {
        let name = Self.name(mode)
        let hint = "\(name): \(Self.hint(mode))"
        if showsLabels {
            return KSegment(value: mode, icon: Self.icon(mode), text: name, hint: hint)
        }
        var segment = KSegment(value: mode, icon: Self.icon(mode), label: name)
        segment.hint = hint
        return segment
    }

    /// One dot = one coloured thing; a palette = every colour; a moon = quiet.
    static func icon(_ mode: ChromaMode) -> String {
        switch mode {
        case .focus: return "circle-dot"
        case .full: return "palette"
        case .calm: return "moon"
        }
    }

    static func name(_ mode: ChromaMode) -> String {
        switch mode {
        case .focus: return String(localized: "chroma.mode.focus", defaultValue: "Focus")
        case .full: return String(localized: "chroma.mode.full", defaultValue: "Full")
        case .calm: return String(localized: "chroma.mode.calm", defaultValue: "Calm")
        }
    }

    static func hint(_ mode: ChromaMode) -> String {
        switch mode {
        case .focus: return String(localized: "chroma.mode.focus.hint", defaultValue: "colour only on the task you are doing")
        case .full: return String(localized: "chroma.mode.full.hint", defaultValue: "every project in its own colour")
        case .calm: return String(localized: "chroma.mode.calm.hint", defaultValue: "no colour, no counts")
        }
    }
}
