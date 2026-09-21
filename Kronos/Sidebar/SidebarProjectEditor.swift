// Kronos/Sidebar/SidebarProjectEditor.swift
// Create / rename a project: name, icon + colour identity, area. Presented as a popover
// from a sidebar row's context menu and from the "+" on the Areas section header.
//
// Icon replaces emoji: identity is icon + colour, picked from KIconPicker's
// curated monochrome set; KEmojiPicker has left this editor. `KProject.icon` still
// round-trips through `createProject`/`updateProject`.
//
// Core gap: TaskStoring has no per-project archive/restore mutation and dedicated archive
// control in this editor (context menu has it); area changes save via `moveProject`. Archive
// and "move to area" stay on the row's context menu (SidebarScreen), which already calls
// `archiveProject`/`moveProject` directly, rather than being duplicated in here.
//
// Colour modes: the swatch picker always shows real colours (you are choosing one), and the
// preview glyph is forced to Full for the same reason. Calm applies to the sidebar, not here.
import SwiftUI
import KronosCore

struct SidebarProjectEditor: View {
    enum Mode: Equatable {
        case create(area: KArea?)
        case rename(KProject)
    }

    let model: AppModel
    let mode: Mode
    let areas: [KArea]
    let onDone: () -> Void

    @State private var name: String
    @State private var color: Color
    @State private var icon: String?
    @State private var selectedAreaID: UUID?

    init(model: AppModel, mode: Mode, areas: [KArea], onDone: @escaping () -> Void) {
        self.model = model
        self.mode = mode
        self.areas = areas
        self.onDone = onDone
        switch mode {
        case .create(let area):
            _name = State(initialValue: "")
            _color = State(initialValue: KProjectPalette.swatches[6].color)
            _icon = State(initialValue: nil)
            _selectedAreaID = State(initialValue: area?.id)
        case .rename(let project):
            _name = State(initialValue: project.name)
            _color = State(initialValue: Color(hex: SidebarProjectEditor.hexValue(project.colorHex)))
            _icon = State(initialValue: project.icon)
            _selectedAreaID = State(initialValue: project.area?.id)
        }
    }

    private var isRename: Bool { if case .rename = mode { return true }; return false }
    private var titleKey: String { isRename ? "sidebar.projecteditor.title.edit" : "sidebar.projecteditor.title.new" }

    var body: some View {
        // Save/Cancel are pinned outside the ScrollView so they're reachable at 380x640
        // without scrolling (ledger fix) — only the pickers, which can legitimately grow
        // taller than any fixed popover height, scroll.
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: String.LocalizationValue(titleKey)))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
                .padding(Space.x4)

            KHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    HStack(spacing: Space.x3) {
                        KProjectGlyph(icon: icon, color: color, size: Metrics.iconXL + 8, style: .plate)
                            // While choosing a colour the preview always shows it, whatever the mode.
                            .environment(\.chromaMode, .full)
                        // "+" rows land the name field ready for typing; Return saves, Esc
                        // cancels, empty cancels (create mode only).
                        KTextField(String(localized: "sidebar.projecteditor.name"), text: $name, autofocus: !isRename)
                            .onSubmit { if !name.trimmingCharacters(in: .whitespaces).isEmpty { save() } else { onDone() } }
                            .onExitCommand(perform: onDone)
                    }

                    VStack(alignment: .leading, spacing: Space.x2) {
                        Text(String(localized: "sidebar.projecteditor.color")).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                        KColorSwatchPicker(selected: $color)
                    }

                    VStack(alignment: .leading, spacing: Space.x2) {
                        Text(String(localized: "iconpicker.title")).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                        KIconPicker(selection: $icon)
                    }

                    VStack(alignment: .leading, spacing: Space.x2) {
                        Text(String(localized: "sidebar.projecteditor.area")).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                        KMenuButton(text: selectedAreaName) {
                            Button(String(localized: "sidebar.projecteditor.noarea")) { selectedAreaID = nil }
                            ForEach(areas) { area in
                                Button(area.name) { selectedAreaID = area.id }
                            }
                        }
                    }

                    // Context folders only apply to a project that already exists — a
                    // brand-new one in `.create` has no id yet to key
                    // `CoachSettings.projectFolders` by, so the section only shows once
                    // renaming an existing project.
                    if case .rename(let existingProject) = mode {
                        KHairline()
                        SidebarProjectFolders(model: model, project: existingProject)
                    }
                }
                .padding(Space.x4)
            }

            KHairline()

            HStack {
                Button(String(localized: "common.cancel"), action: onDone)
                    .kButton(.secondary)
                Spacer()
                Button(String(localized: "sidebar.projecteditor.save"), action: save)
                    .kButton(.primary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Space.x4)
        }
        // Matches the inspector's own scale (Metrics.inspectorMin) rather than a magic
        // literal — comfortably fits KIconPicker's 252pt-wide grid with room to spare, and
        // keeps the margin inside the gate's 380pt-wide snapshot canvas that OLED corners
        // depend on (a popover exactly as wide as the canvas touches all four corners).
        .frame(width: Metrics.inspectorMin)
        .background(Tok.overlay)
    }

    private var selectedAreaName: String {
        areas.first { $0.id == selectedAreaID }?.name ?? String(localized: "sidebar.projecteditor.noarea")
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let area = areas.first { $0.id == selectedAreaID }
        switch mode {
        case .create:
            model.store.createProject(name: trimmed, colorHex: color.hexString, icon: icon, area: area)
        case .rename(let project):
            model.store.updateProject(project.id, name: trimmed, colorHex: color.hexString,
                                       icon: .some(icon), emoji: nil)
            // The Area menu is editable here too: without this the choice was silently dropped.
            if project.area?.id != area?.id { model.store.moveProject(project.id, toArea: area) }
        }
        model.didMutate()
        onDone()
    }

    private static func hexValue(_ hex: String) -> UInt32 {
        UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8224E3
    }
}

extension Color {
    /// Round-trips through `KProject.colorHex`. Resolved against the standard sRGB profile
    /// so a swatch picked from `KProjectPalette` (already sRGB) encodes back losslessly.
    var hexString: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
