// Kronos/List/ListViewOptionsPopoverContent.swift
// The content behind KViewOptionsIconButton: Sort / Filter / Display, wired to the real
// per-scope ViewOptions via ViewOptionsMapper. Changes apply live — every edit writes
// straight through `model.setOptions(_:for:)`, no Apply button. Exposed as a named
// snapshot screen (`list.viewoptions`) since popovers can't be captured while presented.
//
// "Save as view…" / "Update view" (Core rev 4: createSavedView/updateSavedView). The
// button reads "Save as view…" for a fixed scope or an unmodified saved view, and opens
// `ListSaveViewSheet` (exposed as `list.saveview`) to name the new view. For an open
// `.savedView` scope whose sort/filter differ from the stored view, the button instead
// reads "Update view" and writes straight through `updateSavedView` — no naming step.
import SwiftUI
import KronosCore

struct ListViewOptionsPopoverContent: View {
    @Bindable var model: AppModel
    let scope: ListScope
    @State private var showSaveView = false

    var body: some View {
        let opts = model.options(for: scope)
        KViewOptionsPopover {
            sortSection(opts)
        } filter: {
            filterSection(opts)
        } display: {
            displaySection(opts)
        }
        .popover(isPresented: $showSaveView) {
            ListSaveViewSheet(name: "") { name in
                let view = model.store.createSavedView(name: name, filter: opts.filter, sort: opts.sort, showDone: opts.showCompleted)
                model.didMutate()
                model.scope = .savedView(view.id)
                showSaveView = false
            } onCancel: {
                showSaveView = false
            }
        }
    }

    /// The open saved view, when `scope` is one and it still exists.
    private var openSavedView: KSavedView? {
        guard case .savedView(let id) = scope else { return nil }
        return model.store.allSavedViews().first { $0.id == id }
    }

    /// True when `scope` is an open saved view whose stored sort/filter/showDone differ
    /// from the current (live-applied) `opts` — the signal for "Update view" vs "Save as
    /// view…", and for whether tapping the button updates in place or opens the namer.
    private func isModifiedSavedView(_ opts: ViewOptions) -> Bool {
        guard let view = openSavedView else { return false }
        return view.filter != opts.filter || view.sortDescriptors != opts.sort || view.showDone != opts.showCompleted
    }

    // MARK: - Sort

    private func sortSection(_ opts: ViewOptions) -> some View {
        let binding = Binding<[KSortRule]>(
            get: { ViewOptionsMapper.sortRules(from: opts.sort) },
            set: { rules in
                var o = opts
                o.sort = ViewOptionsMapper.descriptors(from: rules)
                model.setOptions(o, for: scope)
            }
        )
        return KSortBuilder(rules: binding, availableFields: ViewOptionsMapper.sortFields)
    }

    // MARK: - Filter

    private func filterSection(_ opts: ViewOptions) -> some View {
        let rules = ViewOptionsMapper.filterRules(from: opts.filter, projectName: projectName, areaName: areaName, labelName: labelName)
        let binding = Binding<[KFilterRule]>(
            get: { rules },
            set: { newRules in applyRuleEdit(newRules, previous: rules, opts: opts) }
        )
        return KFilterBuilder(rules: binding, availableFields: ViewOptionsMapper.filterFields, onAdd: { field in
            addFilterField(field, opts: opts)
        }, valueMenu: { field in
            valueMenu(for: field, opts: opts)
        })
    }

    /// KFilterBuilder mutates the rule array directly: a row disappearing is a removal, an
    /// `isNegated` flip is `KFilterRuleRow`'s own toggle writing back through `$rule` — value
    /// edits happen separately via the menu's own onPick callbacks below. `setNegated` is
    /// used rather than writing `KFilter.negated` directly so the array stays sorted (byte-
    /// identical export depends on it — Filtering.swift).
    private func applyRuleEdit(_ newRules: [KFilterRule], previous: [KFilterRule], opts: ViewOptions) {
        var f = opts.filter
        if newRules.count < previous.count {
            let removed = Set(previous.map(\.id)).subtracting(newRules.map(\.id))
            for rule in previous where removed.contains(rule.id) {
                clear(ViewOptionsMapper.filterFieldID(rule.field), from: &f)
            }
        } else {
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            for rule in newRules {
                guard let was = previousByID[rule.id], was.isNegated != rule.isNegated else { continue }
                let id = ViewOptionsMapper.filterFieldID(rule.field)
                if let coreField = ViewOptionsMapper.coreField(id) {
                    f.setNegated(coreField, rule.isNegated)
                } else {
                    // Boolean fields have no negation flag (spec: their true/false value IS
                    // the is/is-not answer) — the row's "is"/"is not" toggle flips the value.
                    toggleBoolValue(id, in: &f)
                }
            }
        }
        var o = opts
        o.filter = f
        model.setOptions(o, for: scope)
    }

    private func clear(_ id: ViewOptionsMapper.FilterFieldID, from f: inout KFilter) {
        switch id {
        case .status: f.statuses = []
        case .priority: f.priorities = []
        case .effort: f.efforts = []
        case .depth: f.depths = []
        case .project: f.projectIDs = []; f.noProject = false
        case .area: f.areaIDs = []
        case .label: f.labelIDs = []
        case .deadline: f.due = .any; f.dueFrom = nil; f.dueTo = nil
        case .hasSubtasks: f.hasSubtasks = nil
        case .hasNotes: f.hasNotes = nil
        case .isSomeday: f.isSomeday = nil
        case .needsTriage: f.needsTriage = nil
        case .dread: f.dread = nil
        case .text: f.text = ""
        }
    }

    private func toggleBoolValue(_ id: ViewOptionsMapper.FilterFieldID, in f: inout KFilter) {
        switch id {
        case .hasSubtasks: f.hasSubtasks = f.hasSubtasks.map { !$0 }
        case .hasNotes: f.hasNotes = f.hasNotes.map { !$0 }
        case .isSomeday: f.isSomeday = f.isSomeday.map { !$0 }
        case .needsTriage: f.needsTriage = f.needsTriage.map { !$0 }
        case .dread: f.dread = f.dread.map { !$0 }
        default: break
        }
    }

    private func addFilterField(_ field: KSortFilterField, opts: ViewOptions) {
        var f = opts.filter
        switch ViewOptionsMapper.filterFieldID(field) {
        case .hasSubtasks: f.hasSubtasks = true
        case .hasNotes: f.hasNotes = true
        case .isSomeday: f.isSomeday = true
        case .needsTriage: f.needsTriage = true
        case .dread: f.dread = true
        case .deadline: f.due = .today
        case .text: f.text = " "
        default: break // multi-select fields start empty (inert, shown greyed) until a value is picked
        }
        var o = opts
        o.filter = f
        model.setOptions(o, for: scope)
    }

    @ViewBuilder
    private func valueMenu(for field: KSortFilterField, opts: ViewOptions) -> some View {
        switch ViewOptionsMapper.filterFieldID(field) {
        case .status: multiMenu(KStatus.allCases, current: opts.filter.statuses, name: ViewOptionsMapper.statusName) { self.setStatuses($0, opts) }
        case .priority: multiMenu(KPriority.allCases, current: opts.filter.priorities, name: ViewOptionsMapper.priorityName) { self.setPriorities($0, opts) }
        case .effort: multiMenu(KEffort.allCases, current: opts.filter.efforts, name: ViewOptionsMapper.effortName) { self.setEfforts($0, opts) }
        case .depth: multiMenu(KDepth.allCases, current: opts.filter.depths, name: ViewOptionsMapper.depthName) { self.setDepths($0, opts) }
        case .project: projectMenu(opts)
        case .area: areaMenu(opts)
        case .label: labelMenu(opts)
        case .deadline: deadlineMenu(opts)
        case .hasSubtasks: boolMenu(opts.filter.hasSubtasks ?? true) { self.setBool(\.hasSubtasks, $0, opts) }
        case .hasNotes: boolMenu(opts.filter.hasNotes ?? true) { self.setBool(\.hasNotes, $0, opts) }
        case .isSomeday: boolMenu(opts.filter.isSomeday ?? true) { self.setBool(\.isSomeday, $0, opts) }
        case .needsTriage: boolMenu(opts.filter.needsTriage ?? true) { self.setBool(\.needsTriage, $0, opts) }
        case .dread: boolMenu(opts.filter.dread ?? true) { self.setBool(\.dread, $0, opts) }
        case .text: EmptyView() // text value is typed inline in the row's value control in a fuller build; the field summary already shows the query
        }
    }

    /// One checkable menu row — a checkmark `Label` when `isOn`, plain `Text` otherwise —
    /// erased to `AnyView` because a `Menu`'s ForEach/Group content does not accept a
    /// per-row conditional return type without it (SwiftUI ViewBuilder limitation).
    private func checkableRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AnyView(isOn ? AnyView(Label(title, systemImage: "checkmark")) : AnyView(Text(title)))
        }
    }

    private func multiMenu<T: CaseIterable & Hashable>(_ all: T.AllCases, current: [Int], name: @escaping (T) -> String, apply: @escaping ([Int]) -> Void) -> some View where T: RawRepresentable, T.RawValue == Int {
        ForEach(Array(all), id: \.self) { option in
            checkableRow(name(option), isOn: current.contains(option.rawValue)) {
                var set = Set(current)
                if set.contains(option.rawValue) { set.remove(option.rawValue) } else { set.insert(option.rawValue) }
                apply(Array(set).sorted())
            }
        }
    }

    private func boolMenu(_ current: Bool, apply: @escaping (Bool) -> Void) -> some View {
        Group {
            checkableRow("is true", isOn: current) { apply(true) }
            checkableRow("is false", isOn: !current) { apply(false) }
        }
    }

    private func projectMenu(_ opts: ViewOptions) -> some View {
        Group {
            checkableRow("No project", isOn: opts.filter.noProject) {
                var f = opts.filter; f.noProject.toggle()
                var o = opts; o.filter = f; model.setOptions(o, for: scope)
            }
            ForEach(model.store.allProjects(), id: \.id) { p in
                checkableRow(p.name, isOn: opts.filter.projectIDs.contains(p.id)) {
                    toggle(p.id, in: opts.filter.projectIDs) { var f = opts.filter; f.projectIDs = $0; var o = opts; o.filter = f; model.setOptions(o, for: scope) }
                }
            }
        }
    }

    private func areaMenu(_ opts: ViewOptions) -> some View {
        ForEach(distinctAreas, id: \.id) { a in
            checkableRow(a.name, isOn: opts.filter.areaIDs.contains(a.id)) {
                toggle(a.id, in: opts.filter.areaIDs) { var f = opts.filter; f.areaIDs = $0; var o = opts; o.filter = f; model.setOptions(o, for: scope) }
            }
        }
    }

    private func labelMenu(_ opts: ViewOptions) -> some View {
        ForEach(distinctLabels, id: \.id) { l in
            checkableRow(l.name, isOn: opts.filter.labelIDs.contains(l.id)) {
                toggle(l.id, in: opts.filter.labelIDs) { var f = opts.filter; f.labelIDs = $0; var o = opts; o.filter = f; model.setOptions(o, for: scope) }
            }
        }
    }

    private func toggle(_ id: UUID, in current: [UUID], apply: ([UUID]) -> Void) {
        var set = Set(current)
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        apply(Array(set))
    }

    private var distinctAreas: [KArea] {
        var seen = Set<UUID>()
        return model.store.allProjects().compactMap(\.area).filter { seen.insert($0.id).inserted }
    }

    private var distinctLabels: [KLabel] {
        var seen = Set<UUID>()
        return model.store.allTasks().flatMap { $0.labels ?? [] }.filter { seen.insert($0.id).inserted }
    }

    private func deadlineMenu(_ opts: ViewOptions) -> some View {
        let today = Day.today()
        return Group {
            windowButton(.overdue, label: String(localized: "list.filter.due.overdue"), opts: opts)
            windowButton(.today, label: String(localized: "list.filter.due.today"), opts: opts)
            windowButton(.next7, label: String(localized: "list.filter.due.week"), opts: opts)
            windowButton(.next30, label: "Next 30 days", opts: opts)
            windowButton(.none, label: String(localized: "list.filter.due.none"), opts: opts)
            checkableRow("Custom range", isOn: opts.filter.due == .custom) {
                var f = opts.filter; f.due = .custom; f.dueFrom = today; f.dueTo = today + 7
                var o = opts; o.filter = f; model.setOptions(o, for: scope)
            }
        }
    }

    private func windowButton(_ window: KFilter.DueWindow, label: String, opts: ViewOptions) -> some View {
        checkableRow(label, isOn: opts.filter.due == window) {
            var f = opts.filter; f.due = window
            var o = opts; o.filter = f; model.setOptions(o, for: scope)
        }
    }

    private func setStatuses(_ v: [Int], _ opts: ViewOptions) { var f = opts.filter; f.statuses = v; var o = opts; o.filter = f; model.setOptions(o, for: scope) }
    private func setPriorities(_ v: [Int], _ opts: ViewOptions) { var f = opts.filter; f.priorities = v; var o = opts; o.filter = f; model.setOptions(o, for: scope) }
    private func setEfforts(_ v: [Int], _ opts: ViewOptions) { var f = opts.filter; f.efforts = v; var o = opts; o.filter = f; model.setOptions(o, for: scope) }
    private func setDepths(_ v: [Int], _ opts: ViewOptions) { var f = opts.filter; f.depths = v; var o = opts; o.filter = f; model.setOptions(o, for: scope) }
    private func setBool(_ path: WritableKeyPath<KFilter, Bool?>, _ v: Bool, _ opts: ViewOptions) {
        var f = opts.filter; f[keyPath: path] = v
        var o = opts; o.filter = f; model.setOptions(o, for: scope)
    }

    // MARK: - Display

    private func displaySection(_ opts: ViewOptions) -> some View {
        let showCompleted = Binding<Bool>(
            get: { opts.showCompleted },
            set: { var o = opts; o.showCompleted = $0; model.setOptions(o, for: scope) }
        )
        let modified = isModifiedSavedView(opts)
        return VStack(alignment: .leading, spacing: Space.x3) {
            KToggleRow(String(localized: "viewoptions.showcompleted"), isOn: showCompleted)
            Button(String(localized: modified ? "viewoptions.updateview" : "viewoptions.saveview")) {
                if modified, let view = openSavedView {
                    model.store.updateSavedView(view.id, name: nil, filter: opts.filter, sort: opts.sort, showDone: opts.showCompleted)
                    model.didMutate()
                } else {
                    showSaveView = true
                }
            }
            .kButton(.secondary)
        }
    }

    // MARK: - Name lookups

    private func projectName(_ id: UUID) -> String? { model.store.allProjects().first { $0.id == id }?.name }
    private func areaName(_ id: UUID) -> String? { model.store.allProjects().compactMap(\.area).first { $0.id == id }?.name }
    private func labelName(_ id: UUID) -> String? { model.store.allTasks().flatMap { $0.labels ?? [] }.first { $0.id == id }?.name }
}
