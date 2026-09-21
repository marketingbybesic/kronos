// Kronos/Settings/SettingsOrdoTab.swift
// Ordo presets, editable. Built-ins (deadline/quickwins/deepwork/priority/coach) are locked —
// "Duplicate" copies one into an editable custom preset, so editing/duplicating/reordering
// never lets a rename or a bad sort silently break a built-in default every other screen
// falls back to. Every mutation goes through `model.coach.update` / `model.coach.applyPreset`,
// the one mechanism the coach model already gives every screen (CoachModel.swift's own
// comment: "one mechanism: everything ... follows").
import SwiftUI
import KronosCore

struct SettingsOrdoTab: View {
    let model: AppModel
    @State private var editingPresetID: String?
    @State private var scopeForDefault: ListScope = .inbox
    /// The menu bar can show a subtask before or after its parent task, configurable here —
    /// read once into @State so the pickers below are ordinary bindings; every change writes
    /// straight through to the hermetic `MenuBarPrefs` (MenuBarOrdoController reads it live via
    /// UserDefaults.didChangeNotification, same wiring as Settings > Appearance's own
    /// menu-bar width slider).
    @State private var titleMode: MenuBarTitleMode = MenuBarPrefs.titleMode
    @State private var fillToCamera: Bool = MenuBarPrefs.fillToCamera
    @State private var menuBarPoints: Double = MenuBarPrefs.maxPoints

    var body: some View {
        SettingsSection(title: String(localized: "settings.ordo.section.presets")) {
            Text(String(localized: "settings.ordo.presets.help"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Space.x1)
            ForEach(model.coach.settings.presets) { preset in
                presetRow(preset)
                if editingPresetID == preset.id {
                    presetEditor(preset)
                }
            }
            SettingsTrailingRow {
                Text(String(localized: "settings.ordo.builtin.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }

        SettingsSection(title: String(localized: "settings.ordo.section.defaults")) {
            SettingsRow(label: String(localized: "settings.ordo.scope")) {
                Picker("", selection: $scopeForDefault) {
                    ForEach(ListScope.fixed, id: \.self) { scope in
                        Text(String(localized: String.LocalizationValue(scope.titleKey ?? "sidebar.inbox"))).tag(scope)
                    }
                    ForEach(model.store.allProjects(includeArchived: false), id: \.id) { project in
                        Text(project.name).tag(ListScope.project(project.id))
                    }
                }
                .labelsHidden()
                .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
            }
            SettingsRow(label: String(localized: "settings.ordo.defaultpreset")) {
                Picker("", selection: Binding(
                    get: { model.coach.activePreset(for: scopeForDefault).id },
                    set: { id in model.coach.applyPreset(id, to: scopeForDefault) }
                )) {
                    ForEach(model.coach.settings.presets) { preset in
                        Text(presetName(preset)).tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
            }
        }

        SettingsSection(title: String(localized: "settings.ordo.section.menubar")) {
            SettingsRow(label: String(localized: "settings.ordo.menubar.shows")) {
                Picker("", selection: $titleMode) {
                    Text(String(localized: "settings.ordo.menubar.shows.subtasktask")).tag(MenuBarTitleMode.subtaskThenTask)
                    Text(String(localized: "settings.ordo.menubar.shows.tasksubtask")).tag(MenuBarTitleMode.taskThenSubtask)
                    Text(String(localized: "settings.ordo.menubar.shows.subtaskonly")).tag(MenuBarTitleMode.subtaskOnly)
                    Text(String(localized: "settings.ordo.menubar.shows.taskonly")).tag(MenuBarTitleMode.taskOnly)
                }
                .labelsHidden()
                .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
                .onChange(of: titleMode) { _, v in MenuBarPrefs.titleMode = v }
            }
            SettingsRow(label: String(localized: "settings.ordo.menubar.fill")) {
                Toggle("", isOn: $fillToCamera)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .onChange(of: fillToCamera) { _, v in MenuBarPrefs.fillToCamera = v }
            }
            if !fillToCamera {
                SettingsRow(label: String(localized: "settings.ordo.menubar.width")) {
                    HStack(spacing: Space.x2) {
                        Slider(value: $menuBarPoints, in: MenuBarPrefs.pointsRange, step: 20)
                            .frame(width: 180)
                        Text(String(format: "%.0f", menuBarPoints))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                            .monospacedDigit()
                    }
                    .onChange(of: menuBarPoints) { _, v in MenuBarPrefs.maxPoints = v }
                }
            }
            SettingsHelpRow {
                Text(String(localized: fillToCamera ? "settings.ordo.menubar.fill.help" : "settings.ordo.menubar.width.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
        }
    }

    private func presetRow(_ preset: OrdoPreset) -> some View {
        HStack {
            Text(presetName(preset)).font(Typo.row).foregroundStyle(Tok.textPrimary)
            if preset.isBuiltIn {
                KBadge(String(localized: "settings.ordo.builtin"))
            }
            Spacer()
            if preset.isBuiltIn {
                Button(String(localized: "settings.ordo.duplicate")) {
                    duplicate(preset)
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
            } else {
                Button(editingPresetID == preset.id ? String(localized: "common.done") : String(localized: "common.edit")) {
                    editingPresetID = editingPresetID == preset.id ? nil : preset.id
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
                Button(String(localized: "common.delete")) { delete(preset) }
                    .kButton(.ghost, size: .compact)
                    .fixedSize()
            }
        }
        .frame(height: Metrics.controlRegular)
    }

    @ViewBuilder
    private func presetEditor(_ preset: OrdoPreset) -> some View {
        KPanel {
            VStack(alignment: .leading, spacing: Space.x3) {
                KTextField(String(localized: "settings.ordo.name"), text: Binding(
                    get: { preset.name },
                    set: { newName in updatePreset(preset.id) { $0.name = newName } }
                ))
                .frame(width: 220)

                Text(String(localized: "viewoptions.sort.title"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                KSortBuilder(rules: Binding(
                    get: { preset.sort.map { KSortRule(field: Self.field(for: $0.key), ascending: $0.ascending) } },
                    set: { rules in
                        updatePreset(preset.id) { $0.sort = rules.map { KSortDescriptor(key: Self.key(for: $0.field), ascending: $0.ascending) } }
                    }
                ), availableFields: Self.sortFields)

                Text(String(localized: "viewoptions.filter.title"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                priorityFilterRow(preset)

                SettingsRow(label: String(localized: "settings.ordo.coachranking")) {
                    Toggle(isOn: Binding(
                        get: { preset.usesCoachRanking },
                        set: { v in updatePreset(preset.id) { $0.usesCoachRanking = v } }
                    )) { EmptyView() }
                        .toggleStyle(.switch)
                        .tint(Tok.textPrimary)
                        .labelsHidden()
                }
                if preset.usesCoachRanking {
                    SettingsRow(label: String(localized: "settings.coach.defaultenergy")) {
                        KSegmented(selection: Binding(
                            get: { preset.energy ?? .mid },
                            set: { v in updatePreset(preset.id) { $0.energy = v } }
                        ), segments: [
                            KSegment(value: KEnergyLevel.low, text: String(localized: "energy.low")),
                            KSegment(value: KEnergyLevel.mid, text: String(localized: "energy.mid")),
                            KSegment(value: KEnergyLevel.high, text: String(localized: "energy.high")),
                        ])
                    }
                }
            }
        }
    }

    /// The filter surface kept to ONE useful rule (priority) rather than every `KFilter` field:
    /// an Ordo preset reorders a list far more often than it narrows one, and List's own view
    /// options (a different screen, another leaf) already own full multi-field filtering —
    /// duplicating that whole surface here would be scope this tab does not need.
    private func priorityFilterRow(_ preset: OrdoPreset) -> some View {
        let priorityField = KSortFilterField(id: "priority-filter", name: String(localized: "viewoptions.field.priority"), symbol: "flag")
        let hasRule = !preset.filter.priorities.isEmpty
        return KFilterBuilder(rules: Binding(
            get: {
                hasRule ? [KFilterRule(field: priorityField, isNegated: preset.filter.isNegated(.priorities), valueSummary: prioritySummary(preset.filter.priorities))] : []
            },
            set: { rules in
                updatePreset(preset.id) { settings in
                    if let rule = rules.first {
                        settings.filter.setNegated(.priorities, rule.isNegated)
                    } else {
                        settings.filter.priorities = []
                    }
                }
            }
        ), availableFields: hasRule ? [] : [priorityField], onAdd: { _ in
            updatePreset(preset.id) { $0.filter.priorities = [KPriority.high.rawValue, KPriority.urgent.rawValue] }
        }, valueMenu: { _ in
            ForEach(KPriority.allCases, id: \.self) { p in
                Button(priorityName(p)) {
                    updatePreset(preset.id) { settings in
                        var set = Set(settings.filter.priorities)
                        if set.contains(p.rawValue) { set.remove(p.rawValue) } else { set.insert(p.rawValue) }
                        settings.filter.priorities = Array(set).sorted()
                    }
                }
            }
        })
    }

    private func prioritySummary(_ raw: [Int]) -> String {
        raw.compactMap { KPriority(rawValue: $0) }.map(priorityName).joined(separator: ", ")
    }

    private func priorityName(_ p: KPriority) -> String {
        switch p {
        case .none: return String(localized: "priority.none")
        case .low: return String(localized: "priority.low")
        case .medium: return String(localized: "priority.medium")
        case .high: return String(localized: "priority.high")
        case .urgent: return String(localized: "priority.urgent")
        }
    }

    private func presetName(_ preset: OrdoPreset) -> String {
        preset.isBuiltIn ? String(localized: String.LocalizationValue(preset.name)) : preset.name
    }

    private func updatePreset(_ id: String, _ mutate: (inout OrdoPreset) -> Void) {
        model.coach.update { settings in
            guard let i = settings.presets.firstIndex(where: { $0.id == id }) else { return }
            mutate(&settings.presets[i])
        }
    }

    private func duplicate(_ preset: OrdoPreset) {
        let name = String(format: String(localized: "settings.ordo.duplicate.suffix"), presetName(preset))
        let copy = OrdoPreset(id: UUID().uuidString, name: name, sort: preset.sort,
                               filter: preset.filter, usesCoachRanking: preset.usesCoachRanking, energy: preset.energy)
        model.coach.update { $0.presets.append(copy) }
        editingPresetID = copy.id
    }

    private func delete(_ preset: OrdoPreset) {
        model.coach.update { settings in
            settings.presets.removeAll { $0.id == preset.id }
            for (scope, id) in settings.defaultPresetByScope where id == preset.id {
                settings.defaultPresetByScope[scope] = nil
            }
        }
        if editingPresetID == preset.id { editingPresetID = nil }
    }

    // MARK: KSortKey <-> KSortFilterField adapter (design system never imports KronosCore)

    private static let sortFields: [KSortFilterField] = [
        .init(id: KSortKey.manual, name: String(localized: "viewoptions.field.manual"), symbol: "grip-vertical"),
        .init(id: KSortKey.title, name: String(localized: "viewoptions.field.title"), symbol: "pencil"),
        .init(id: KSortKey.priority, name: String(localized: "viewoptions.field.priority"), symbol: "flag"),
        .init(id: KSortKey.effort, name: String(localized: "viewoptions.field.effort"), symbol: "sliders"),
        .init(id: KSortKey.deadline, name: String(localized: "viewoptions.field.deadline"), symbol: "calendar"),
        .init(id: KSortKey.project, name: String(localized: "viewoptions.field.project"), symbol: "folder"),
        .init(id: KSortKey.depth, name: String(localized: "viewoptions.field.depth"), symbol: "brain"),
    ]

    private static func field(for key: KSortKey) -> KSortFilterField {
        sortFields.first { ($0.id as? KSortKey) == key } ?? sortFields[0]
    }

    private static func key(for field: KSortFilterField) -> KSortKey {
        (field.id as? KSortKey) ?? .manual
    }
}
