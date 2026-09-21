// Kronos/Sidebar/SidebarAreaEditor.swift
// Create or rename an area and edit its colour. Presented as a popover from the Areas
// header's "+" (create) and an area row's context menu ("ctx.area.rename").
//
// Core gap: `updateArea(_:colorHex:icon:)` takes an icon as a raw SF Symbol string, but the
// design system has no icon-picker component (only KColorSwatchPicker for colour and
// KEmojiPicker for project emoji, neither of which fits a bare SF Symbol name) — icon editing
// is left at its current value rather than inventing a picker outside the design system.
import SwiftUI
import KronosCore

struct SidebarAreaEditor: View {
    enum Mode: Equatable {
        case create
        case edit(KArea)
    }

    let model: AppModel
    let mode: Mode
    let onDone: () -> Void

    @State private var name: String
    @State private var color: Color

    init(model: AppModel, mode: Mode, onDone: @escaping () -> Void) {
        self.model = model
        self.mode = mode
        self.onDone = onDone
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _color = State(initialValue: KProjectPalette.swatches[6].color)
        case .edit(let area):
            _name = State(initialValue: area.name)
            _color = State(initialValue: Color(hex: SidebarAreaEditor.hexValue(area.colorHex)))
        }
    }

    private var isCreate: Bool { if case .create = mode { return true }; return false }
    private var titleKey: String { isCreate ? "sidebar.areaeditor.title.new" : "sidebar.areaeditor.title.edit" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: String.LocalizationValue(titleKey)))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
                .padding(Space.x4)

            KHairline()

            VStack(alignment: .leading, spacing: Space.x4) {
                // "+" rows land the name field ready for typing; Return saves, Esc cancels,
                // empty cancels (create mode only — renaming an existing area already has a
                // name, autofocus there would just re-select it for no reason).
                KTextField(String(localized: "sidebar.projecteditor.name"), text: $name, autofocus: isCreate)
                    .onSubmit { if !name.trimmingCharacters(in: .whitespaces).isEmpty { save() } else { onDone() } }
                    .onExitCommand(perform: onDone)

                VStack(alignment: .leading, spacing: Space.x2) {
                    Text(String(localized: "ctx.area.iconcolor")).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    KColorSwatchPicker(selected: $color)
                }
            }
            .padding(Space.x4)

            KHairline()

            HStack {
                Button(String(localized: "common.cancel"), action: onDone)
                    .kButton(.secondary)
                Spacer()
                Button(String(localized: "common.save"), action: save)
                    .kButton(.primary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Space.x4)
        }
        .frame(width: Metrics.inspectorMin)
        .background(Tok.overlay)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .create:
            _ = model.store.createArea(name: trimmed, colorHex: color.hexString, icon: "square.grid.2x2")
        case .edit(let area):
            model.store.groupedUndo("Edit area") {
                model.store.renameArea(area.id, name: trimmed)
                model.store.updateArea(area.id, colorHex: color.hexString, icon: nil)
            }
        }
        model.didMutate()
        onDone()
    }

    private static func hexValue(_ hex: String) -> UInt32 {
        UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8B8B93
    }
}
