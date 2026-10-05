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
    /// Filter fields added in "Add filter" that have no value yet: each shows as a "Choose…" row until one is
    /// picked. Nothing is stored for them, so they end with the popover.
    @State private var pendingFilterFields: [ViewOptionsMapper.FilterFieldID] = []
#if !RELEASE
    /// The live test opens the popover as if "Add filter" had just been used on these fields (a menu
    /// cannot be clicked from inside the app); consumed by the next popover that appears.
    static var seedPending: [ViewOptionsMapper.FilterFieldID] = []
#endif

    var body: some View {
        let opts = currentOptions()
        KViewOptionsPopover(clearAll: opts.hasRulesToClear(keepingPin: pin) ? { ListViewReset.clearAll(model: model, scope: scope) } : nil) {
            sortSection(opts)
        } filter: {
            filterSection(opts)
        } display: {
            displaySection(opts)
        }
        .onAppear {
#if !RELEASE
            if !Self.seedPending.isEmpty { pendingFilterFields = Self.seedPending; Self.seedPending = [] }
#endif
        }
        .popover(isPresented: $showSaveView) {
            ListSaveViewSheet(name: "", projectName: savePin.flatMap(projectName)) { name in
                // Saved inside a project (or from one of its views) the view belongs to that project.
                let filter = savePin.map(opts.filter.pinned(to:)) ?? opts.filter
                let view = model.store.createSavedView(name: name, filter: filter, sort: opts.sort, showDone: opts.showCompleted)
                model.commit(String(format: String(localized: "list.pill.viewsaved"), view.name))
                model.scope = .savedView(view.id)
                showSaveView = false
            } onCancel: {
                showSaveView = false
            }
        }
    }

    /// The project a view saved from this list belongs to: the open project, or the project of the open view.
    private var savePin: UUID? {
        if case .project(let id) = scope { return id }
        return pin
    }

    /// The project the open saved view belongs to (its rule is locked), else nil.
    private var pin: UUID? { ListViewReset.pin(model: model, scope: scope) }

    /// The list's options as the editor uses them, with a saved view's pin always in place so no edit made
    /// from here can write a view without it.
    private func currentOptions() -> ViewOptions {
        ListViewReset.pinned(model.viewOptions(for: scope), model: model, scope: scope)
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
                model.setOptions(ViewOptionsMapper.sortEdit(rules, on: opts), for: scope)
            }
        )
        return KSortBuilder(rules: binding, availableFields: ViewOptionsMapper.offeredSortFields(for: scope.shape, showCompleted: opts.showCompleted))
    }

    // MARK: - Filter

    private func filterSection(_ opts: ViewOptions) -> some View {
        // The pinned project is drawn as its own locked row above the builder: it is not a rule that can
        // be removed, inverted or replaced here.
        var editable = opts.filter
        if pin != nil { editable.clear(.project) }
        let rules = ViewOptionsMapper.filterRules(from: editable, compact: true, pending: pendingFilterFields,
                                                  projectName: projectName, areaName: areaName, labelName: labelName)
        let binding = Binding<[KFilterRule]>(
            get: { rules },
            set: { newRules in applyRuleEdit(newRules, previous: rules, opts: opts) }
        )
        var used = Set(rules.map { ViewOptionsMapper.filterFieldID($0.field) })
        if pin != nil { used.insert(.project) }
        return VStack(alignment: .leading, spacing: Space.x2) {
            if let pin { pinnedProjectRow(pin) }
            KFilterBuilder(
                rules: binding,
                availableFields: ViewOptionsMapper.offeredFilterFields(for: scope.shape, excluding: used),
                textValue: { field in
                    guard ViewOptionsMapper.filterFieldID(field) == .text else { return nil }
                    return Binding<String>(
                        get: { currentOptions().filter.text },
                        set: { setText($0) })
                },
                textPlaceholder: String(localized: "viewoptions.filter.text.placeholder"),
                onAdd: { field in addFilterField(field, opts: opts) },
                valueMenu: { field in valueMenu(for: field, opts: opts) })
        }
    }

    /// The project a saved view belongs to, in the shape of a filter row but without the controls: no
    /// operator toggle, no value menu and a lock where the X would be.
    private func pinnedProjectRow(_ projectID: UUID) -> some View {
        let field = ViewOptionsMapper.filterField(.project)
        let name = projectName(projectID) ?? String(localized: "viewoptions.pinned.missing")
        return HStack(spacing: Space.x2) {
            HStack(spacing: Space.x2) {
                Icon(field.symbol, size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                Text(field.name).font(Typo.row).foregroundStyle(Tok.textSecondary).lineLimit(1)
            }
            .frame(width: Metrics.ruleFieldColumn, alignment: .leading)
            Text(String(localized: "viewoptions.op.is"))
                .font(Typo.row)
                .foregroundStyle(Tok.textTertiary)
                .frame(width: Metrics.ruleOperatorColumn, height: Metrics.minHit, alignment: .leading)
            Text(name)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Icon("lock", size: Metrics.iconXS)
                .foregroundStyle(Tok.textDisabled)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
        }
        .help(String(localized: "viewoptions.pinned.help"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(field.name) \(name)")
        .accessibilityHint(String(localized: "viewoptions.pinned.help"))
        .uiTestAnchor("filter.pinned")
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
                let id = ViewOptionsMapper.filterFieldID(rule.field)
                f = ViewOptionsMapper.clearing(id, from: f)
                pendingFilterFields.removeAll { $0 == id }
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
                    f = ViewOptionsMapper.togglingBool(id, in: f)
                }
            }
        }
        write(f, opts)
    }

    /// "Add filter > field": the yes/no fields and the deadline start with a value; every other field gets
    /// a "Choose…" row whose menu (or text field) sets the value.
    private func addFilterField(_ field: KSortFilterField, opts: ViewOptions) {
        let id = ViewOptionsMapper.filterFieldID(field)
        let (f, needsValue) = ViewOptionsMapper.adding(id, to: opts.filter)
        if needsValue, !pendingFilterFields.contains(id) { pendingFilterFields.append(id) }
        write(f, opts)
    }

    private func setText(_ text: String) {
        // The row stays while the text is emptied (it is being edited), until its X removes it.
        if !pendingFilterFields.contains(.text) { pendingFilterFields.append(.text) }
        var o = currentOptions()
        o.filter.text = text
        model.setOptions(o, for: scope)
    }

    /// Stores `filter` on `opts` when it differs from what is there.
    private func write(_ filter: KFilter, _ opts: ViewOptions) {
        guard filter != opts.filter else { return }
        var o = opts
        o.filter = filter
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
        case .text: EmptyView() // typed inline in the row (KFilterBuilder `textValue`), never picked from a menu
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
                apply(ViewOptionsMapper.toggling(option.rawValue, in: current, sortedBy: <))
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
        apply(ViewOptionsMapper.toggling(id, in: current, sortedBy: { $0.uuidString < $1.uuidString }))
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

    private func setStatuses(_ v: [Int], _ opts: ViewOptions) { write(ViewOptionsMapper.setting(.status, ints: v, in: opts.filter), opts) }
    private func setPriorities(_ v: [Int], _ opts: ViewOptions) { write(ViewOptionsMapper.setting(.priority, ints: v, in: opts.filter), opts) }
    private func setEfforts(_ v: [Int], _ opts: ViewOptions) { write(ViewOptionsMapper.setting(.effort, ints: v, in: opts.filter), opts) }
    private func setDepths(_ v: [Int], _ opts: ViewOptions) { write(ViewOptionsMapper.setting(.depth, ints: v, in: opts.filter), opts) }
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
            // A Waiting or Someday list holds no closed task: the switch would do nothing there.
            if scope.shape.offersShowCompleted {
                KToggleRow(String(localized: "viewoptions.showcompleted"), isOn: showCompleted)
                    .uiTestAnchor("viewoptions.showcompleted")
            }
            Button(String(localized: modified ? "viewoptions.updateview" : "viewoptions.saveview")) {
                if modified, let view = openSavedView {
                    model.store.updateSavedView(view.id, name: nil, filter: opts.filter, sort: opts.sort, showDone: opts.showCompleted)
                    model.commit(String(format: String(localized: "list.pill.viewupdated"), view.name))
                } else {
                    showSaveView = true
                }
            }
            .kButton(.secondary)
            .uiTestAnchor("viewoptions.saveview")
        }
    }

    // MARK: - Name lookups

    private func projectName(_ id: UUID) -> String? { model.store.allProjects().first { $0.id == id }?.name }
    private func areaName(_ id: UUID) -> String? { model.store.allProjects().compactMap(\.area).first { $0.id == id }?.name }
    private func labelName(_ id: UUID) -> String? { model.store.allTasks().flatMap { $0.labels ?? [] }.first { $0.id == id }?.name }
}
