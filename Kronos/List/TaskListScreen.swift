// Kronos/List/TaskListScreen.swift
// The task list for every ListScope: header + search + the ONE view-options icon, an
// active-rules chip bar shown only when rules are active, an inline new-task row, and the
// sorted/filtered rows themselves. Toolbar has nothing else — no chevrons, no per-field
// buttons.
import SwiftUI
import KronosCore

struct TaskListScreen: View {
    @Bindable var model: AppModel
    /// Snapshot-only; see CoachBanner.swift. Always nil on the real screen.
    var previewBlockSuggestion: BlockSuggestion?? = nil
    @State private var showPopover = false
    // Not `private`: TaskListScreen+Parts.swift's extension (the Now card) reads/writes it.
    @State var isNowCardCollapsed = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    /// "E": open or close every subtask list at once.
    @State private var allSubtasksExpanded = false

    // MARK: - Calm-mode visibility (Now card, chip row, header count)
    //
    // Read straight off `model.chromaMode` rather than `@Environment(\.chromaMode)`: the
    // environment value is for HUE decisions only (`Chroma.tint`, inside the design
    // system) and every real screen sets it from this same `model.chromaMode` one level up
    // (AppShellView), so the two never disagree there. The snapshot harness, though,
    // builds its root view once as a plain local value and applies `.environment(...)`
    // outside any reactive View body — a fixture that mutates `model.chromaMode` in its
    // own `.onAppear` (columnsList, below) never reaches that frozen environment value,
    // while `model` itself (an `@Observable` reference this view already holds via
    // `@Bindable`) reflects the mutation immediately, in the harness exactly as in the
    // real app. This is a visibility decision, not a colour one, so reading the model
    // directly is not the "branch on chromaMode to pick a colour" the design system forbids.
    private var isCalm: Bool { model.chromaMode == .calm }

    var body: some View {
        let ctx = context
        VStack(alignment: .leading, spacing: 0) {
            header(ctx)
            if !isCalm, ctx.activeRuleCount > 0 {
                KActiveRulesBar(chips: chips(ctx), onReset: resetOptions)
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x2)
            }
            CoachBannerSlot(model: model, previewSuggestion: previewBlockSuggestion, isCalm: isCalm)
            // The Now card toggle (Settings > Appearance > Layout,
            // `CoachSettings.nowCardEnabled`) is the ONLY thing gating this card; it used to
            // also hide under `!isCalm`, so Calm mode silently overrode a setting the user had
            // turned on. Calm mode still hides the rules bar and header count above/below
            // (unrelated), but the Now card itself no longer depends on chromaMode at all.
            if model.coach.settings.nowCardEnabled, let focusTask = focusTask {
                nowCard(focusTask, ctx)
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x3)
            }
            KHairline().padding(.top, Space.x3)
            body(ctx)
        }
        .background(Tok.bg)
        .onAppear {
            publishOrdo(ctx)
            pruneSelection(ctx)
            validateFocusPin()
            // The list is the default first responder: without an explicit initial focus, a
            // fresh window/snapshot auto-assigns first responder to the first focusable
            // control in the tree, which was the view-options icon button — showing a focus
            // ring at rest with nothing focused on purpose.
            listFocused = true
        }
        .onChange(of: model.version) { _, _ in publishOrdo(context); pruneSelection(context); validateFocusPin() }
        .onChange(of: model.scope) { _, _ in publishOrdo(context); pruneSelection(context) }
        .onChange(of: model.searchText) { _, _ in publishOrdo(context); pruneSelection(context) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosViewOptionsRequested"))) { _ in
            showPopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosFocusSearchRequested"))) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosFocusListRequested"))) { _ in
            listFocused = true
        }
    }

    // MARK: - Header

    private func header(_ ctx: ListContext) -> some View {
        HStack(spacing: Space.x3) {
            HStack(spacing: Space.x2) {
                if case .project(let id) = model.scope, let project = model.store.allProjects().first(where: { $0.id == id }) {
                    KProjectGlyph(icon: project.icon, colorHex: project.colorHex, size: Metrics.iconL)
                }
                Text(ctx.title)
                    .font(Typo.display)
                    .tracking(Tracking.tight)
                    .foregroundStyle(Tok.textPrimary)
                if !isCalm {
                    Text("\(ctx.rows.count)")
                        .font(Typo.count)
                        .foregroundStyle(Tok.textTertiary)
                }
            }
            Spacer(minLength: Space.x4)
            KTextField(String(localized: "sidebar.search.placeholder"), text: $model.searchText, leading: "search")
                .frame(maxWidth: 260)
                .focused($searchFocused)
            KViewOptionsIconButton(activeCount: ctx.activeRuleCount) { showPopover.toggle() }
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    ListViewOptionsPopoverContent(model: model, scope: model.scope)
                }
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.toolbarHeight)
    }

    // MARK: - Now card
    // nowCard/nowCardAttributes/nowCardDeadlineText moved to TaskListScreen+Parts.swift
    // (pure move, no behaviour change — file-length budget after main's hotkey registry
    // additions).

    /// The pinned-or-automatic focus task, looked up directly from the store — NOT from
    /// `ctx.rows` — so the card still shows it when a filter/search has excluded it from
    /// the visible rows below (G9: "the card shows the focus task even when filtered out").
    private var focusTask: KTask? {
        guard let id = model.focusTaskID else { return nil }
        return model.store.task(id)
    }

    private func chips(_ ctx: ListContext) -> [KActiveRulesBar.RuleChip] {
        var chips: [KActiveRulesBar.RuleChip] = []
        if ctx.options.sort != KSortDescriptor.default {
            for (i, d) in ctx.options.sort.enumerated() {
                chips.append(.init(id: "sort.\(i)", text: ViewOptionsMapper.sortChipText(d), onTap: { showPopover = true }, onRemove: {
                    var opts = ctx.options
                    opts.sort.remove(at: i)
                    if opts.sort.isEmpty { opts.sort = KSortDescriptor.default }
                    model.setOptions(opts, for: model.scope)
                }))
            }
        }
        if ctx.options.filter != .empty {
            let texts = ViewOptionsMapper.filterChipTexts(ctx.options.filter, projectName: projectName, areaName: areaName, labelName: labelName)
            for (i, text) in texts.enumerated() {
                chips.append(.init(id: "filter.\(i)", text: text, onTap: { showPopover = true }, onRemove: {
                    removeFilterRule(at: i, from: ctx.options)
                }))
            }
        }
        return chips
    }

    private func removeFilterRule(at index: Int, from options: ViewOptions) {
        let rules = ViewOptionsMapper.filterRules(from: options.filter, projectName: projectName, areaName: areaName, labelName: labelName)
        guard rules.indices.contains(index) else { return }
        var f = options.filter
        switch ViewOptionsMapper.filterFieldID(rules[index].field) {
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
        var opts = options
        opts.filter = f
        model.setOptions(opts, for: model.scope)
    }

    private func resetOptions() {
        model.setOptions(.default, for: model.scope)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(_ ctx: ListContext) -> some View {
        if ctx.rows.isEmpty && model.searchText.isEmpty && ctx.activeRuleCount == 0 {
            // An empty list still starts with the same "New task" row every other list has:
            // without it an empty area or project offered no visible way to add the first task.
            VStack(alignment: .leading, spacing: 0) {
                ListInlineNewTaskRow(model: model, scope: model.scope)
                    .padding(.horizontal, Space.x3)
                    .padding(.vertical, Space.x2)
                KEmptyState(icon: emptyIcon, title: emptyTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GeometryReader { geo in
                // ColumnMode is computed ONCE here from the measured list width and handed
                // identically to every row — never decided per row: letting each row fit its
                // own content independently allowed two rows to
                // disagree about which optional columns exist, which broke alignment the
                // same way an unconstrained slot width did. Budget: list width minus the
                // scroll view's own horizontal padding, the row's leading chrome (edge inset
                // + checkbox + gap to title) and trailing inset, minus a floor for the title
                // itself so long titles keep truncating instead of being crushed to zero.
                let chrome = Space.x3 * 2 + Metrics.listRowLeading + Metrics.listCheckboxSize
                    + Metrics.listCheckboxTitleGap + Metrics.listRowTrailing
                let titleFloor: CGFloat = 120
                let trailingBudget = geo.size.width - chrome - titleFloor
                let columnMode = ColumnMode.fitting(available: trailingBudget)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.x1) {
                        ListInlineNewTaskRow(model: model, scope: model.scope)
                        ForEach(ctx.rows, id: \.id) { task in
                            ListRowView(model: model, task: task, ctx: ctx,
                                        isSelected: model.selectedTaskID == task.id,
                                        showProjectGlyph: showsProjectGlyph,
                                        columnMode: columnMode,
                                        onSelect: { model.selectedTaskID = task.id; listFocused = true })
                        }
                        if ctx.rows.isEmpty {
                            KEmptyState(icon: "search", title: noMatchesTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Space.x3)
                    .padding(.vertical, Space.x2)
                }
            }
            .focusable(true)
            .focusEffectDisabled()   // selection is shown by the row, never by a system ring
            .focused($listFocused)
            // Registry ids, Kronos/Hotkeys/HotkeyRegistry.swift scope .list.
            .onKeyPress(.upArrow) { guard !Self.isTyping else { return .ignored }; moveSelection(-1, ctx); return .handled }
            .onKeyPress(.downArrow) { guard !Self.isTyping else { return .ignored }; moveSelection(1, ctx); return .handled }
            .onKeyPress(.space) { guard !Self.isTyping else { return .ignored }; toggleSelected(ctx); return .handled }
            .onKeyPress(.deleteForward) { guard !Self.isTyping else { return .ignored }; deleteSelected(ctx); return .handled }
            .onKeyPress(.delete) { guard !Self.isTyping else { return .ignored }; deleteSelected(ctx); return .handled }
            .onKeyPress(.return) { guard !Self.isTyping else { return .ignored }; selectAndOpen(ctx); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "hHfFeEoO01234")) { press in
                guard !Self.isTyping else { return .ignored }
                handleCharacter(press.characters, ctx)
                return .handled
            }
        }
    }

    private var showsProjectGlyph: Bool {
        switch model.scope {
        case .project: return false
        default: return true
        }
    }

    private var emptyIcon: String {
        switch model.scope {
        case .inbox: return "inbox"
        case .today: return "sun"
        case .next7: return "calendar-days"
        case .waiting: return "hourglass"
        case .someday: return "archive"
        case .all: return "list-ordered"
        case .project, .area, .savedView: return "folder"
        }
    }

    /// "No matches" empty state shown when rules/search exclude everything. The query
    /// shown is the search text when present, else a plain description of the active
    /// filter rules — `empty.search.query` is a %@ format string either way.
    private var noMatchesTitle: String {
        // With no search text the emptiness comes from filter rules: say that, instead of
        // quoting the word "Filter" as if it were a query (seen on the live window).
        guard !model.searchText.isEmpty else { return String(localized: "empty.filter.nomatch") }
        return String(format: String(localized: "empty.search.query"), model.searchText)
    }

    private var emptyTitle: String {
        switch model.scope {
        case .inbox: return String(localized: "empty.inbox.body")
        case .today: return String(localized: "empty.today.body")
        case .next7: return String(localized: "empty.next7.body")
        case .waiting: return String(localized: "empty.waiting.body")
        case .someday: return String(localized: "empty.someday.body")
        case .all: return String(localized: "empty.view.body")
        case .project, .area: return String(localized: "empty.project.body")
        case .savedView: return String(localized: "empty.view.body")
        }
    }

    // MARK: - Selection hygiene

    /// Clears the inspector selection when the selected task is no longer among the
    /// visible rows (scope switch, a rule now excludes it, search narrows it out, it was
    /// completed/deleted). Never picks a new selection on its own — the bug this guards
    /// against was the inspector showing a task while the list was empty, not the absence of
    /// an auto-selected replacement.
    private func pruneSelection(_ ctx: ListContext) {
        guard let id = model.selectedTaskID, !ctx.rows.contains(where: { $0.id == id }) else { return }
        model.selectedTaskID = nil
    }

    // MARK: - Keyboard

    private func moveSelection(_ delta: Int, _ ctx: ListContext) {
        guard !ctx.rows.isEmpty else { return }
        guard let current = model.selectedTaskID, let i = ctx.rows.firstIndex(where: { $0.id == current }) else {
            model.selectedTaskID = ctx.rows.first?.id
            return
        }
        let next = max(0, min(ctx.rows.count - 1, i + delta))
        model.selectedTaskID = ctx.rows[next].id
    }

    private func toggleSelected(_ ctx: ListContext) {
        guard let id = model.selectedTaskID, let task = ctx.rows.first(where: { $0.id == id }) else { return }
        ListCompletion.toggle(task, store: model.store, model: model)
    }

    private func deleteSelected(_ ctx: ListContext) {
        guard let id = model.selectedTaskID, let task = ctx.rows.first(where: { $0.id == id }) else { return }
        model.store.softDelete(task.id)
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "undo.deleted.name"), task.title))
    }

    /// Return: today the inspector already tracks `model.selectedTaskID` reactively and
    /// opens on it — clicking a row does exactly this. Return does the same thing a click
    /// does, nothing more (no separate "open" state to invent).
    private func selectAndOpen(_ ctx: ListContext) {
        guard let id = model.selectedTaskID, ctx.rows.contains(where: { $0.id == id }) else { return }
        model.selectedTaskID = id
    }

    /// Single-key row actions — dispatched from the one `.onKeyPress(characters:)` above so
    /// they share its "list must have focus, not a text field" gate. snooze/focuspin match
    /// against the registry's CURRENT binding (Kronos/Hotkeys/HotkeyRegistry.swift), so a
    /// future rebind takes effect with no code change; the priority digits are fixed.
    /// True while a text field owns the keyboard. The list container reports itself focused even
    /// when focus is in the inline field INSIDE it, so a FocusState check let space, Return, o, h, f
    /// and 0-4 be eaten while typing (the live UI test typed "Buy oat milk" and got "Buyatmilk").
    private static var isTyping: Bool {
        // Not only keyWindow: it is nil for a moment whenever the app is not frontmost, and the
        // keys would be eaten again exactly then.
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?.firstResponder is NSTextView
    }

    private func handleCharacter(_ characters: String, _ ctx: ListContext) {
        guard let id = model.selectedTaskID, let task = ctx.rows.first(where: { $0.id == id }) else { return }
        let pressed = characters.lowercased()
        switch pressed {
        case HotkeyRegistry.current(for: "list.snooze")?.key: snoozeTask(task)
        case HotkeyRegistry.current(for: "list.focuspin")?.key: toggleFocusPin(task)
        case HotkeyRegistry.current(for: "list.expandall")?.key:
            allSubtasksExpanded.toggle()
            NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: allSubtasksExpanded)
        case "0", "o": setPriority(task, .none)   // "o" too: a zero reads as the letter in the guide
        case "1": setPriority(task, .low)
        case "2": setPriority(task, .medium)
        case "3": setPriority(task, .high)
        case "4": setPriority(task, .urgent)
        default: break
        }
    }

    private func snoozeTask(_ task: KTask) {
        model.store.snooze(task.id)
        model.didMutate()
    }

    private func setPriority(_ task: KTask, _ priority: KPriority) {
        model.store.setPriority(task.id, priority)
        model.didMutate()
    }

    private func toggleFocusPin(_ task: KTask) {
        model.pinnedFocusTaskID = model.pinnedFocusTaskID == task.id ? nil : task.id
    }

    /// UI_CONTRACT_REV 4: clear the pin when its task is done, deleted or missing, checked
    /// on every `model.version` bump (any store mutation) and once on appear. `store.task`
    /// already excludes soft-deleted rows, so "deleted" and "missing" are the same nil case.
    private func validateFocusPin() {
        guard let id = model.pinnedFocusTaskID else { return }
        let task = model.store.task(id)
        if task == nil || task?.status == .done { model.pinnedFocusTaskID = nil }
    }

    // MARK: - Ordo

    private func publishOrdo(_ ctx: ListContext) {
        guard let first = ctx.rows.first(where: { KStatus.open.contains($0.status) }) else {
            model.publishOrdoFocus(.empty(listName: ctx.title))
            return
        }
        let remaining = ctx.rows.filter { KStatus.open.contains($0.status) }.count - 1
        model.publishOrdoFocus(OrdoFocus(taskID: first.id, title: first.title, firstMove: first.firstMove,
                                         listName: ctx.title, remaining: max(0, remaining)))
    }

    // MARK: - Name lookups (chips, filter builder)

    private func projectName(_ id: UUID) -> String? { model.store.allProjects().first { $0.id == id }?.name }
    private func areaName(_ id: UUID) -> String? { model.store.allProjects().compactMap(\.area).first { $0.id == id }?.name }
    private func labelName(_ id: UUID) -> String? {
        model.store.allTasks().flatMap { $0.labels ?? [] }.first { $0.id == id }?.name
    }

    // MARK: - Context (scope title + sorted/filtered rows)

    private var context: ListContext { ListContext(model: model) }
}

/// One computed snapshot of "what this scope shows right now" — title, options, final rows —
/// so the header, chips, body and Ordo publisher all read the identical list.
@MainActor
struct ListContext {
    let title: String
    let options: ViewOptions
    let rows: [KTask]
    let activeRuleCount: Int

    init(model: AppModel) {
        let scope = model.scope
        // A `.savedView` scope has no base membership of its own (ScopeFilter.matches
        // returns true for every task): its sort + filter + showDone come FROM the
        // KSavedView itself, not from this leaf's per-scope UserDefaults storage — a saved
        // view is shared state, not a window-local preference. A fixed/project/area scope
        // still reads `model.options(for:)` exactly as before.
        let opts: ViewOptions
        if case .savedView(let id) = scope, let view = model.store.allSavedViews().first(where: { $0.id == id }) {
            opts = ViewOptions(sort: view.sortDescriptors, filter: view.filter, showCompleted: view.showDone)
        } else {
            opts = model.options(for: scope)
        }
        self.options = opts
        self.title = ListContext.title(for: scope, model: model)
        let today = Day.today()

        var filter = opts.filter
        let base = ScopeFilter.baseFilter(for: scope)
        filter.statuses = filter.statuses.isEmpty ? base.statuses : filter.statuses
        if !opts.showCompleted, filter.statuses.isEmpty {
            filter.statuses = KStatus.openRaw
        }
        filter.projectIDs = filter.projectIDs.isEmpty ? base.projectIDs : filter.projectIDs
        filter.areaIDs = filter.areaIDs.isEmpty ? base.areaIDs : filter.areaIDs
        filter.noProject = filter.noProject || base.noProject
        if filter.due == .any { filter.due = base.due }

        let all = model.store.allTasks().filter { ScopeFilter.matches($0, scope: scope, today: today) }
        var matched = all.filter { filter.matches($0, today: today) }
        if !model.searchText.isEmpty {
            let needle = KTextFold.fold(model.searchText)
            matched = matched.filter { KTextFold.fold($0.title).contains(needle) }
        }
        self.rows = KTaskSorter.sorted(matched, by: opts.sort)
        self.activeRuleCount = ViewOptionsMapper.activeRuleCount(sort: opts.sort, filter: opts.filter)
    }

    private static func title(for scope: ListScope, model: AppModel) -> String {
        if let key = scope.titleKey { return String(localized: String.LocalizationValue(key)) }
        switch scope {
        case .project(let id): return model.store.allProjects().first { $0.id == id }?.name ?? "Project"
        case .area(let id): return model.store.allProjects().compactMap(\.area).first { $0.id == id }?.name ?? "Area"
        case .savedView(let id): return model.store.allSavedViews().first { $0.id == id }?.name ?? "View"
        default: return ""
        }
    }
}
