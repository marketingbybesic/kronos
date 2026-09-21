// Kronos/MenuBar/MenuBarPresetEnergyRow.swift
// PRESET + ENERGY — the Ordo preset switcher (keeps the ranking logic easy to change
// without opening Settings) and the energy picker (feeds the Coach preset).
// Both are quiet controls, not a settings screen: switching a preset here is exactly
// `model.coach.applyPreset(_:to:)`, the SAME mechanism the window's own view-options and
// Settings > Ordo will use, so list, Now card, sidebar tint and this popover always agree.
import SwiftUI
import KronosCore

struct MenuBarPresetRow: View {
    let presets: [OrdoPreset]
    let activeID: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: Space.x2) {
            Text(String(localized: "menubar.preset.title"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize()
            Spacer(minLength: Space.x2)
            KMenuButton(text: displayName(for: activeID)) {
                ForEach(presets) { preset in
                    Button(displayName(for: preset.id)) { onSelect(preset.id) }
                }
            } leading: {
                Icon("sliders", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            }
        }
    }

    /// Built-ins name themselves with a loc key ("ordo.preset.deadline", …) per
    /// `OrdoPreset`'s own doc comment — all five now exist in the catalog. A custom
    /// (non-built-in) preset's `name` is the user's own literal typed text, not a key.
    private func displayName(for id: String) -> String {
        guard let preset = presets.first(where: { $0.id == id }) else { return id }
        guard preset.isBuiltIn else { return preset.name }
        return String(localized: String.LocalizationValue(preset.name))
    }
}

struct MenuBarEnergyRow: View {
    @Binding var energy: KEnergyLevel

    var body: some View {
        HStack(spacing: Space.x2) {
            Text(String(localized: "menubar.energy.title"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize()
            Spacer(minLength: Space.x2)
            KSegmented(selection: $energy, segments: [
                .init(value: .low, text: String(localized: "energy.low")),
                .init(value: .mid, text: String(localized: "energy.mid")),
                .init(value: .high, text: String(localized: "energy.high")),
            ])
        }
    }
}
