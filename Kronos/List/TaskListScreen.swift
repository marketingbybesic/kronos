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
    @Environment(\.kAccent) private var accent
    // Not `private`: TaskListScreen+Parts.swift's extension (the Now card) reads/writes it.
    // One global key (not per scope): a user who folds the card wants it folded everywhere.
    @State var isNowCardCollapsed = UserDefaults.standard.bool(forKey: "kronos.nowcard.collapsed")
    @State var hotkeyRevision = 0   // bumped on HotkeyRegistry.changed so the key filter below re-reads the bindings
    @FocusState private var searchFocused: Bool
    @FocusState var listFocused: Bool   // not private: TaskListScreen+Bulk.swift
    /// "E": open or close every subtask list at once.
    @State var allSubtasksExpanded = false   // not private: TaskListScreen+Keys.swift
    /// Rows Today showed at the last look (nil: not looking at an unfiltered Today). The
    /// day-clear cue plays on the move from some rows to none (TodayClear).
    @State private var lastTodayRows: Int?
    /// The moving end of a ⇧↑/⇧↓ range (the anchor is `model.selectedTaskID`); nil after a plain move.
    @State var rangeCursor: UUID?   // not private: TaskListScreen+Keys.swift

    /// Calm mode was removed in rev18; this stays false so the header count always shows.
    private var isCalm: Bool { false }
    
    // MARK: - Calm-mode visibility (Now card, chip row, header count)
    //
    // Read straight off `model.chromaMode` rather than `@Environment(\.chromaMode)`: the
    // environment value is for HUE decisions only (`Chroma.tint`, inside the design
    // system) and every real screen sets it from this same `model.chromaMode` one level up
    // (AppShellView), so the two never disagree there. The snapshot harness, though,
    // builds its root view once as a plain local value and applies `.environment(...)`
    // outside any reactive View body — a fixture that mutates `model.chromaMode` in its
    // own `.onAppear` (columnsList, below) never reaches that frozen environment value,
    // Calm mode was removed in rev18; active rules bar is always visible when filters apply.

    var body: some View {
        let ctx = context
        VStack(alignment: .leading, spacing: 0) {
            header(ctx)
            if ruleCount(ctx) > 0 {
                KActiveRulesBar(chips: chips(ctx), onReset: resetOptions)
                    .uiTestAnchor("rules.bar")
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x2)
            }
            if ListSortDragHint.shared.isShowing(for: model.scope), !ctx.options.isManualOrder {
                ListSortDragHintBar(model: model, scope: model.scope)
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x2)
            }
            CoachBannerSlot(model: model, previewSuggestion: previewBlockSuggestion, isCalm: isCalm)
            // "Start here" (Kronos/Welcome/OnboardingCard.swift): renders nothing unless a tour runs.
            OnboardingCard(model: model)
                .tourAnchor(.learnCard)
                .padding(.horizontal, Space.x4)
                .padding(.top, Space.x3)
            // The Now card toggle (Settings > Appearance > Layout,
            // `CoachSettings.nowCardEnabled`) is the ONLY thing gating this card; it used to
            // also hide under `!isCalm`, so Calm mode silently overrode a setting the user had
            // turned on. Calm mode still hides the rules bar and header count above/below
            // (unrelated), but the Now card itself no longer depends on chromaMode at all.
            if model.coach.settings.nowCardEnabled, showsNowCard(ctx), let focusTask = focusTask {
                nowCard(focusTask, ctx)
                    .tourAnchor(.nowCard)
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x3)
            }
            KHairline().padding(.top, Space.x3)
            body(ctx)
        }
        .background(Tok.bg)
        .announcesUndoPills()
        .onAppear {
            publishOrdo(ctx)
            pruneSelection(ctx)
            validateFocusPin()
            lastTodayRows = TodayClear.observedRows(ctx, model: model)
            // The list is the default first responder: without an explicit initial focus, a
            // fresh window/snapshot auto-assigns first responder to the first focusable
            // control in the tree, which was the view-options icon button — showing a focus
            // ring at rest with nothing focused on purpose.
            listFocused = true
        }
        .onChange(of: model.version) { _, _ in
            let ctx = context
            publishOrdo(ctx); pruneSelection(ctx); validateFocusPin()
            lastTodayRows = TodayClear.track(previous: lastTodayRows, ctx, model: model)
        }
        // A scope or search change is a new first look, never a "Today became clear" moment.
        .onChange(of: model.scope) { _, _ in
            ListSortDragHint.shared.dismiss()
            let ctx = context
            publishOrdo(ctx); pruneSelection(ctx)
            lastTodayRows = TodayClear.observedRows(ctx, model: model)
        }
        .onChange(of: model.searchText) { _, _ in
            let ctx = context
            publishOrdo(ctx); pruneSelection(ctx)
            lastTodayRows = TodayClear.observedRows(ctx, model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosViewOptionsRequested"))) { _ in
            showPopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosFocusSearchRequested"))) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIRequests.focusList)) { _ in
            listFocused = true
        }
        .onAppear { GlobalTaskHotkeys.start(model: model) }
    }

    // MARK: - Header

    private func header(_ ctx: ListContext) -> some View {
        HStack(spacing: Space.x3) {
            HStack(spacing: Space.x2) {
                headerMark
                Text(ctx.title)
                    .font(Typo.display)
                    .tracking(Tracking.tight)
                    .foregroundStyle(Tok.textPrimary)
                if !isCalm {
                    Text("\(ctx.currentCount)")
                        .font(Typo.count)
                        .foregroundStyle(Tok.textTertiary)
                }
            }
            Spacer(minLength: Space.x4)
            KTextField(String(localized: "sidebar.search.placeholder"), text: $model.searchText, leading: "search")
                .frame(maxWidth: 260)
                .focused($searchFocused)
            KViewOptionsIconButton(activeCount: ruleCount(ctx)) { showPopover.toggle() }
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    ListViewOptionsPopoverContent(model: model, scope: model.scope)
                }
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.toolbarHeight)
    }

    /// The mark before the view title. A project view shows the project's icon in the project's
    /// colour; every other view shows its own sidebar icon in the user's accent. The monochrome
    /// mode draws both white (`SelectionHue`).
    @ViewBuilder private var headerMark: some View {
        let neutral = model.chromaMode.isNeutralSelection
        if case .project(let id) = model.scope, let project = model.store.allProjects().first(where: { $0.id == id }) {
            KViewMark(icon: project.icon,
                      tint: SelectionHue.resolve(projectHex: project.colorHex, neutral: neutral).color(accent: accent))
        } else {
            KViewMark(icon: model.scope.leadingIcon,
                      tint: SelectionHue.resolve(projectHex: nil, neutral: neutral).color(accent: accent))
        }
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

    /// The filter as chips and the rule count see it: a saved view's own project is where the view lives, not a
    /// rule to show or remove (it is the locked row in the options popover), so it is left out.
    private func visibleFilter(_ options: ViewOptions) -> KFilter {
        var f = options.filter
        if ListViewReset.pin(model: model, scope: model.scope) != nil { f.clear(.project) }
        return f
    }

    private func ruleCount(_ ctx: ListContext) -> Int {
        ViewOptionsMapper.activeRuleCount(sort: ctx.options.sort, filter: visibleFilter(ctx.options))
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
        let shownFilter = visibleFilter(ctx.options)
        if shownFilter != .empty {
            let texts = ViewOptionsMapper.filterChipTexts(shownFilter, projectName: projectName, areaName: areaName, labelName: labelName)
            for (i, text) in texts.enumerated() {
                chips.append(.init(id: "filter.\(i)", text: text, onTap: { showPopover = true }, onRemove: {
                    removeFilterRule(at: i, from: ctx.options)
                }))
            }
        }
        return chips
    }

    private func removeFilterRule(at index: Int, from options: ViewOptions) {
        let shown = visibleFilter(options)
        let rules = ViewOptionsMapper.filterRules(from: shown, projectName: projectName, areaName: areaName, labelName: labelName)
        guard rules.indices.contains(index) else { return }
        var opts = options
        opts.filter = ViewOptionsMapper.clearing(ViewOptionsMapper.filterFieldID(rules[index].field), from: options.filter)
        model.setOptions(opts, for: model.scope)
    }

    private func resetOptions() {
        ListViewReset.clearAll(model: model, scope: model.scope)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(_ ctx: ListContext) -> some View {
        if ctx.totalCount == 0 && model.searchText.isEmpty && ruleCount(ctx) == 0 {
            // An empty list still starts with the same "New task" row every other list has:
            // without it an empty area or project offered no visible way to add the first task.
            VStack(alignment: .leading, spacing: 0) {
                ListInlineNewTaskRow(model: model, scope: model.scope)
                    .padding(.horizontal, Space.x3)
                    .padding(.vertical, Space.x2)
                if model.scope == .today {
                    TodayClearState(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ListEmptyState(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
                    + Metrics.minHit + Space.x1   // the chevron gutter that always precedes the title
                // The title floor grows with the text size: 120 pt holds fewer characters at L than at M.
                let titleFloor: CGFloat = 120 * DSScale.text
                let trailingBudget = geo.size.width - chrome - titleFloor
                let columnMode = ColumnMode.fitting(available: trailingBudget)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.x1) {
                        ListInlineNewTaskRow(model: model, scope: model.scope)
                            .tourAnchor(.newTask)
                        ForEach(ctx.currentRows, id: \.id) { task in
                            row(task, ctx, columnMode)
                        }
                        // Sorted by an attribute some tasks lack: they end the list under their own header.
                        if let key = ctx.missingKey, !ctx.missing.isEmpty {
                            ListMissingHeader(model: model, key: key,
                                              ids: ctx.missing.filter { KStatus.open.contains($0.status) }.map(\.id),
                                              scope: model.scope, total: ctx.missing.count)
                                .padding(.top, Space.x2)
                            ForEach(ctx.openMissingRows, id: \.id) { task in
                                row(task, ctx, columnMode)
                            }
                        }
                        if !ctx.earlier.isEmpty {
                            ListEarlierHeader(model: model, ids: ctx.earlier.map(\.id))
                                .padding(.top, Space.x2)
                            ForEach(ctx.openEarlierRows, id: \.id) { task in
                                row(task, ctx, columnMode)
                            }
                        }
                        if ctx.totalCount == 0 {
                            KEmptyState(icon: "search", title: noMatchesTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Space.x3)
                    .padding(.vertical, Space.x2)
                    // While the bulk bar floats over the bottom, the last rows can still scroll above it.
                    .padding(.bottom, isMultiSelected ? bulkBarClearance : 0)
                }
                // The one drop destination of the list (rows report their frames into it).
                .listDropLayer(model: model, config: dropConfig(ctx))
                // Right-click on the list itself (rows keep their own menu): Clear all, only while a sort or filter is set.
                .contextMenu {
                    if ctx.options.hasRulesToClear(keepingPin: ListViewReset.pin(model: model, scope: model.scope)) {
                        Button(String(localized: "viewoptions.clearall")) { resetOptions() }
                    }
                }
            }
            .focusable(true)
            .focusEffectDisabled()   // selection is shown by the row, never by a system ring
            .focused($listFocused)
            // Only while 2+ rows are selected (TaskListScreen+Bulk.swift). It floats at the bottom, so VoiceOver reads it
            // after the rows it acts on, not between the Now card and the list.
            .overlay { bulkBarOverlay.accessibilitySortPriority(-1) }
            .listKeyLegend { listFocused && !Self.isTyping && !model.isAnyOverlayOpen }   // hold ⌥ (ListKeyLegend.swift)
            .onReceive(NotificationCenter.default.publisher(for: HotkeyRegistry.changed).receive(on: DispatchQueue.main)) { _ in hotkeyRevision += 1 }
            // Registry ids, Kronos/Hotkeys/HotkeyRegistry.swift scope .list. ⇧↑/⇧↓ extend the range.
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard !Self.isTyping else { return .ignored }
                let delta = press.key == .upArrow ? -1 : 1
                if press.modifiers.contains(.shift) { extendSelection(delta, ctx) } else { moveSelection(delta, ctx) }
                return .handled
            }
            .onKeyPress(.space) { guard !Self.isTyping else { return .ignored }; toggleSelected(ctx); return .handled }
            // A real Backspace delivers U+007F, which SwiftUI's `.delete` (U+0008) does NOT match, so
            // the key was dead on hardware while a synthetic U+0008 worked. Match all three spellings.
            .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in
                guard !Self.isTyping else { return .ignored }; deleteSelected(ctx); return .handled
            }
            // Return takes the undo pill's primary action first ("Done. Next: …" → Start), then
            // falls back to opening the selected row.
            .onKeyPress(.return) {
                guard !Self.isTyping else { return .ignored }
                if UndoToastCenter.shared.performPrimary() { return .handled }
                selectAndOpen(ctx)
                return .handled
            }
            .onKeyPress(.escape) { handleEscape() }
            .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { handleSelectAll($0, ctx) }
            .onKeyPress(characters: listCharacterSet) { press in
                guard !Self.isTyping else { return .ignored }
                return handleGrammarKey(press, ctx) ? .handled : .ignored
            }
        }
    }

    private func row(_ task: KTask, _ ctx: ListContext, _ columnMode: ColumnMode) -> some View {
        ListRowView(model: model, task: task, ctx: ctx,
                    isSelected: isRowSelected(task.id),
                    showProjectGlyph: showsProjectGlyph,
                    columnMode: columnMode,
                    onSelect: { handleRowClick(task.id, ctx) })
            .tourAnchor(.firstRow, when: task.id == ctx.rows.first?.id)
    }

    private var showsProjectGlyph: Bool {
        switch model.scope {
        case .project: return false
        default: return true
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

    // MARK: - Selection hygiene

    /// Clears the inspector selection when the selected task is no longer among the
    /// visible rows (scope switch, a rule now excludes it, search narrows it out, it was
    /// completed/deleted). Never picks a new selection on its own — the bug this guards
    /// against was the inspector showing a task while the list was empty, not the absence of
    /// an auto-selected replacement.
    private func pruneSelection(_ ctx: ListContext) {
        pruneBulk(ctx)
        guard let id = model.selectedTaskID, !ctx.rows.contains(where: { $0.id == id }) else { return }
        model.selectedTaskID = nil
    }

    // MARK: - Keyboard
    // Arrows, Space, Delete, Return and the single-key grammar live in TaskListScreen+Keys.swift.

    // snoozeTask / setPriority / toggleFocusPin live in TaskListScreen+Actions.swift (each raises
    // the undo pill, audit D10).

    /// UI_CONTRACT_REV 4: clear the pin when its task is done, deleted or missing, checked
    /// on every `model.version` bump (any store mutation) and once on appear. `store.task`
    /// already excludes soft-deleted rows, so "deleted" and "missing" are the same nil case.
    private func validateFocusPin() {
        guard let id = model.pinnedFocusTaskID else { return }
        let task = model.store.task(id)
        if task == nil || task?.status == .done { model.pinnedFocusTaskID = nil }
    }

    // MARK: - Ordo

    /// "Next" is the first eligible row of the list being shown (the pin wins): done, pending
    /// review, blocked (waits on an open task) and archived-project rows are skipped, so the Now
    /// card and the menu bar never offer something that cannot be started yet. Browsing another
    /// list changes it by design. The head (first eligible ids) is published for the other
    /// readers of "next" (menu bar, MCP, snapshot).
    private func publishOrdo(_ ctx: ListContext) {
        let lookup = model.store.allTasks()
        let eligible = ctx.rows.filter { NextEligibility.isEligible($0, lookup: lookup) }
        model.publishShownListHead(ShownListHead(listName: ctx.title, ids: eligible.map(\.id)))
        guard let first = NextEligibility.pick(pinned: model.pinnedFocusTaskID, rows: ctx.rows, lookup: lookup) else {
            model.publishOrdoFocus(.empty(listName: ctx.title))
            return
        }
        let others = eligible.filter { $0.id != first.id }.count
        model.publishOrdoFocus(OrdoFocus(taskID: first.id, title: first.title, firstMove: first.firstMove,
                                         listName: ctx.title, remaining: others))
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
