// Kronos/Settings/SettingsAppearanceTab.swift
// Colour, fully configurable. Accent + colour mode live here rather than under General, which
// keeps only what is not colour: language, sidebar mode, sounds, launch. Everything here
// resolves through the design system's own `Chroma`/`Accent` — this screen never decides a
// colour itself, only stores the choice.
import SwiftUI
import KronosCore

struct SettingsAppearanceTab: View {
    let model: AppModel
    @State private var accentHex: String?
    @State private var density: String
    @State private var textSize: String
    @State private var nowCardEnabled: Bool
    @State private var carriers: ColourCarriers = AppearancePrefs.colourCarriers
    @State private var colourBy: RowColourBy = AppearancePrefs.colourBy
    @State private var editingSlotID: String?
    @State private var paletteSlots: [PaletteSlot] = ProjectPalettePrefs.slots
    @State private var rejectedSlotID: String?
    /// The row being dragged by its grip and the gap (0...count) its insertion line is drawn in.
    @State private var dragIndex: Int?
    @State private var dragSlot: Int?
    @State private var customHexInput: String = ""

    init(model: AppModel) {
        self.model = model
        _accentHex = State(initialValue: model.coach.settings.accentHex)
        _density = State(initialValue: model.coach.settings.density)
        _textSize = State(initialValue: model.coach.settings.textSize)
        _nowCardEnabled = State(initialValue: model.coach.settings.nowCardEnabled)
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.appearance.section.colour")) {
            Text(String(localized: "accent.picker.title"))
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
            KAccentPicker(selectionHex: $accentHex)
                .onChange(of: accentHex) { _, v in model.coach.update { $0.accentHex = v } }
                .padding(.bottom, Space.x1)

            SettingsRow(label: String(localized: "chroma.mode.title")) {
                KChromaModeSwitch(mode: Binding(get: { model.chromaMode }, set: { model.chromaMode = $0 }), showsLabels: true)
            }
            SettingsHelpRow {
                Text(chromaModeCaption)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }

        SettingsSection(title: String(localized: "settings.appearance.section.layout")) {
            SettingsRow(label: String(localized: "settings.appearance.density")) {
                KSegmented(selection: Binding(get: { density }, set: { newValue in
                    density = newValue
                    model.coach.update { $0.density = newValue }
                    applyScaleLive()
                }), segments: [
                    KSegment(value: "compact", text: String(localized: "settings.appearance.density.compact")),
                    KSegment(value: "regular", text: String(localized: "settings.appearance.density.regular")),
                ])
            }
            SettingsRow(label: String(localized: "settings.appearance.textsize")) {
                KSegmented(selection: Binding(get: { textSize }, set: { newValue in
                    textSize = newValue
                    model.coach.update { $0.textSize = newValue }
                    applyScaleLive()
                }), segments: [
                    KSegment(value: "S", text: String(localized: "settings.appearance.textsize.s")),
                    KSegment(value: "M", text: String(localized: "settings.appearance.textsize.m")),
                    KSegment(value: "L", text: String(localized: "settings.appearance.textsize.l")),
                ])
            }
            SettingsRow(label: String(localized: "settings.appearance.nowcard")) {
                Toggle(isOn: Binding(get: { nowCardEnabled }, set: { newValue in
                    nowCardEnabled = newValue
                    model.coach.update { $0.nowCardEnabled = newValue }
                })) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "settings.appearance.nowcard"))
                    .uiTestAnchor("settings.appearance.nowcard.toggle")
            }
            // One line explaining exact behaviour (Kronos/List/TaskListScreen.swift's
            // `nowCardEnabled` gate, now the only thing deciding whether the card shows, in
            // every colour mode).
            SettingsHelpRow {
                Text(String(localized: "settings.appearance.nowcard.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
        }

        SettingsAdvanced(tab: "appearance") {
            SettingsSection(title: String(localized: "settings.appearance.carriers.title")) {
                carrierToggle(String(localized: "settings.appearance.carriers.focusrow"), $carriers.focusRowGlyph)
                    .uiTestAnchor("settings.appearance.carriers.focusrow")
                carrierToggle(String(localized: "settings.appearance.carriers.nowcard"), $carriers.nowCard)
                carrierToggle(String(localized: "settings.appearance.carriers.sidebar"), $carriers.sidebarProject)
                carrierToggle(String(localized: "settings.appearance.carriers.menubar"), $carriers.menuBarTitle)
                    .onChange(of: carriers) { _, v in AppearancePrefs.colourCarriers = v }

                KHairline().padding(.vertical, Space.x1)

                SettingsRow(label: String(localized: "settings.appearance.colourby")) {
                    Picker("", selection: $colourBy) {
                        Text(String(localized: "settings.appearance.colourby.project")).tag(RowColourBy.project)
                        Text(String(localized: "settings.appearance.colourby.priority")).tag(RowColourBy.priority)
                        Text(String(localized: "settings.appearance.colourby.effort")).tag(RowColourBy.effort)
                        Text(String(localized: "settings.appearance.colourby.none")).tag(RowColourBy.none)
                    }
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "settings.appearance.colourby"))
                    .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
                    .onChange(of: colourBy) { _, v in AppearancePrefs.colourBy = v }
                }
            }

            SettingsSection(title: String(localized: "settings.appearance.section.palette")) {
                Text(String(localized: "settings.appearance.palette.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                paletteEditor
                    .uiTestAnchor("settings.appearance.palette")
            }
        }
    }

    /// The three mode hints, one line each — reuses KChromaModeSwitch's own strings so this
    /// caption can never drift from what the switch's tooltips already say.
    private var chromaModeCaption: String {
        ChromaMode.allCases.map { mode in
            "\(KChromaModeSwitch.name(mode)): \(KChromaModeSwitch.hint(mode))"
        }.joined(separator: "  ·  ")
    }

    /// `DSScale` used to be read once at launch (AppDelegate) with nothing to re-apply it
    /// live, so a density change had no visible effect until relaunch. Re-running
    /// `apply(...)` now, right after the change lands in `CoachSettings`, then bumping
    /// `model.didMutate()` makes every mounted screen re-evaluate its body on the freshly
    /// scaled `Metrics`/`Typo` values — the same `model.version` re-render every store
    /// mutation already triggers (see DSScale.swift for why this is the fix instead of an
    /// observable DSScale).
    private func applyScaleLive() {
        DSScale.apply(density: density, textSize: textSize)
        model.didMutate()
    }

    private func carrierToggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        SettingsRow(label: label) {
            Toggle(isOn: binding) { EmptyView() }
                .toggleStyle(.switch)
                .tint(Tok.textPrimary)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    // MARK: Palette editor

    private var paletteEditor: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            ForEach(Array(paletteSlots.enumerated()), id: \.element.id) { index, slot in
                paletteRow(slot, index: index)
                    .overlay(alignment: .top) { if dragSlot == index { PaletteInsertionLine().offset(y: -Space.x1 / 2 - 1) } }
                    .overlay(alignment: .bottom) {
                        if dragSlot == paletteSlots.count, index == paletteSlots.count - 1 { PaletteInsertionLine().offset(y: Space.x1 / 2 + 1) }
                    }
            }
        }
    }

    /// Drag by the grip: the row under the pointer decides the gap, the line shows it while the pointer moves, and
    /// letting go files the row there. The arrows beside the grip do the same one step at a time, from the keyboard.
    private func paletteDrag(index: Int) -> some Gesture {
        let pitch = Double(Metrics.controlRegular + Space.x1)
        return DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                let target = PaletteReorder.targetIndex(from: index, translation: Double(value.translation.height), pitch: pitch, count: paletteSlots.count)
                dragIndex = index
                dragSlot = PaletteReorder.insertionSlot(from: index, target: target)
            }
            .onEnded { value in
                let target = PaletteReorder.targetIndex(from: index, translation: Double(value.translation.height), pitch: pitch, count: paletteSlots.count)
                if let slot = PaletteReorder.insertionSlot(from: index, target: target) {
                    ProjectPalettePrefs.move(fromOffsets: IndexSet(integer: index), toOffset: PaletteReorder.moveOffset(forSlot: slot))
                    paletteSlots = ProjectPalettePrefs.slots
                }
                dragIndex = nil
                dragSlot = nil
            }
    }

    // A plain VStack + ForEach has no reorder gesture of its own (that needs a `List` in edit mode,
    // which this scroll pane is not), so the grip carries a DragGesture and the arrows stay as the
    // keyboard and VoiceOver path. Every control is at least 24 x 24 pt.
    private func paletteRow(_ slot: PaletteSlot, index: Int) -> some View {
        let baseHex = KProjectPalette.swatches.first(where: { $0.name == slot.baseName })?.hex ?? "FFFFFF"
        let resolvedHex = slot.resolvedHex(baseHex: baseHex)
        return HStack(spacing: Space.x2) {
            Icon("grip-vertical", size: Metrics.iconXS)
                .foregroundStyle(dragIndex == index ? Tok.textPrimary : Tok.textTertiary)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .contentShape(Rectangle())
                .gesture(paletteDrag(index: index))
                .accessibilityLabel(String(localized: "settings.appearance.palette.drag"))
                .uiTestAnchor("settings.appearance.palette.grip.\(slot.id)")
            HStack(spacing: 0) {
                moveButton(icon: "chevron-up", enabled: index > 0, slotID: slot.id) {
                    ProjectPalettePrefs.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                    paletteSlots = ProjectPalettePrefs.slots
                }
                moveButton(icon: "chevron-down", enabled: index < paletteSlots.count - 1, slotID: slot.id) {
                    ProjectPalettePrefs.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                    paletteSlots = ProjectPalettePrefs.slots
                }
            }
            Circle()
                .fill(Color(hexString: resolvedHex))
                .frame(width: 18, height: 18)
            Text(KProjectPalette.displayName(for: slot.baseName))
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
            if slot.customHex != nil {
                Text(String(localized: "settings.appearance.palette.custom"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Button(String(localized: "settings.appearance.palette.reset")) {
                    ProjectPalettePrefs.resetToDefault(slot.id)
                    paletteSlots = ProjectPalettePrefs.slots
                }
                .kButton(.ghost, size: .compact)
                .fixedSize()
            }
            Spacer()
            if editingSlotID == slot.id {
                replaceEditor(for: slot)
            } else {
                Button(String(localized: "settings.appearance.palette.replace")) {
                    editingSlotID = slot.id
                    rejectedSlotID = nil
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
            }
        }
        .frame(height: Metrics.controlRegular)
    }

    private func moveButton(icon: String, enabled: Bool, slotID: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(icon, size: Metrics.iconXS)
                .foregroundStyle(enabled ? Tok.textTertiary : Tok.textDisabled)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .uiTestAnchor("settings.appearance.palette.\(icon == "chevron-up" ? "up" : "down").\(slotID)")
        .accessibilityLabel(String(localized: icon == "chevron-up" ? "settings.appearance.palette.moveup" : "settings.appearance.palette.movedown"))
    }

    /// `KColorSwatchPicker` only ever offers the same 12 known swatches — every one of them
    /// already clears the contrast floor, so it alone could never demonstrate a genuine
    /// "custom colour, contrast-checked" replacement. A plain hex field is the actual custom
    /// input; the swatch picker stays underneath as the fast path back to a stock colour.
    @ViewBuilder
    private func replaceEditor(for slot: PaletteSlot) -> some View {
        VStack(alignment: .trailing, spacing: Space.x2) {
            KColorSwatchPicker(selected: Binding(
                get: { Color(hexString: slot.resolvedHex(baseHex: KProjectPalette.swatches.first(where: { $0.name == slot.baseName })?.hex ?? "FFFFFF")) },
                set: { newColor in applyReplacement(newColor.toHexString(), to: slot) }
            ))
            HStack(spacing: Space.x2) {
                KTextField("#RRGGBB", text: $customHexInput)
                    .frame(width: 120)
                Button(String(localized: "settings.appearance.palette.apply")) {
                    applyReplacement(customHexInput, to: slot)
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
                .disabled(customHexInput.isEmpty)
            }
            if rejectedSlotID == slot.id {
                Text(String(localized: "settings.appearance.palette.rejected"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            Button(String(localized: "common.cancel")) { editingSlotID = nil; rejectedSlotID = nil; customHexInput = "" }
                .kButton(.ghost, size: .compact)
                .fixedSize()
        }
    }

    private func applyReplacement(_ hex: String, to slot: PaletteSlot) {
        if ProjectPalettePrefs.replace(slot.id, withHex: hex) {
            paletteSlots = ProjectPalettePrefs.slots
            editingSlotID = nil
            rejectedSlotID = nil
            customHexInput = ""
        } else {
            rejectedSlotID = slot.id
        }
    }
}

private extension Color {
    /// Round-trips a `KColorSwatchPicker` selection (one of the 12 known swatches, or — once
    /// a real free-colour picker exists — an arbitrary NSColor) back to a hex string for
    /// `ProjectPalettePrefs.replace`. Matches a known swatch by value first so the common case
    /// never depends on colour-space rounding.
    func toHexString() -> String {
        if let match = KProjectPalette.swatches.first(where: { $0.color == self }) { return match.hex }
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return String(format: "%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

/// The accent line with a dot at its start that marks where a dragged palette row will land, the same mark the
/// inspector draws for a dragged step.
private struct PaletteInsertionLine: View {
    @Environment(\.kAccent) private var accent
    private let dot: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(accent).frame(height: 2)
            Circle().fill(accent).frame(width: dot, height: dot).offset(x: -dot / 2)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .uiTestAnchor("settings.appearance.palette.insertion")
    }
}
