// Kronos/Flow/FlowScreen.swift
// Flow (Kronos v1.2 Phase 2 slice E): a to-do-native dependency graph. Replaces the list in the
// center pane (Kronos/App/AppShellView.swift) whenever the current scope's `ViewOptions.layout`
// is `.flow` — sidebar and inspector stay exactly as they are (AppShellView's own swap).
//
// This file owns layout/state; the columns grid + Canvas edges live in FlowColumnsView.swift,
// the agent-lane alternate view in FlowLanesView.swift, the card in FlowCardView.swift, the W/H
// popovers in FlowPickers.swift, the keyboard in FlowScreen+Keys.swift, and the run/agent-state
// reads in FlowRuns.swift.
import SwiftUI
import KronosCore

/// One build of "what Flow shows right now" — the scoped task set, the layout result and the
/// lookups the rest of this file needs — computed ONCE per body evaluation (`FlowLayout.build`
/// is not free) and threaded through instead of recomputed per callback, the same shape
/// `ListContext` gives `TaskListScreen`.
struct FlowContext {
    let tasks: [KTask]
    let tasksByID: [UUID: KTask]
    let result: FlowLayout.Result
    let runStore: RunStore?
    var visibleIDs: [UUID] { result.columns.flatMap(\.taskIDs) }
    /// Plan F's "Milestones" rule (>= 2 open direct dependents): an edge's `from` is always an
    /// open task (FlowLayout.swift's own rule 6), so counting how often an id is an edge's
    /// `from` IS the open-dependent count — no separate KronosCore helper needed here.
    var gateIDs: Set<UUID> {
        var counts: [UUID: Int] = [:]
        for edge in result.edges { counts[edge.from, default: 0] += 1 }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }
}

struct FlowScreen: View {
    @Bindable var model: AppModel

    // Not `private`: FlowScreen+Keys.swift's extension reads/writes every one of these.
    @State var lanesMode = false
    @State var showAllOverride = false
    @State var showWaitsOnPicker = false
    @State var showHandoff = false
    @State var handoffLaunchesHarness = false
    /// The dependency edge just crossed by ←/→, if any — what ⌫ removes (E5: "removes the
    /// selected dependency when an edge is focused"). Any other navigation or a direct click
    /// clears it, since focus has moved off that edge onto a plain card.
    @State var focusedEdge: FlowLayout.Edge?
    @State private var showViewOptions = false
    @FocusState private var flowFocused: Bool

    private var today: Int { Day.today() }

    var body: some View {
        let _ = model.version   // re-read after any store mutation, same rule every list screen follows
        let ctx = flowContext()

        VStack(alignment: .leading, spacing: 0) {
            // Merge integration (plan F1): the project header strip tops the project's Flow the
            // same way it tops the project's list (TaskListScreen mounts the identical view).
            if case .project(let projectID) = model.scope {
                ProjectHeaderStrip(model: model, projectID: projectID)
            }
            header(ctx)
            selectionHeader(ctx)
            KHairline().padding(.top, Space.x2)
            content(ctx)
        }
        .background(Tok.bg)
        .focusable(true)
        .focusEffectDisabled()
        .focused($flowFocused)
        // Flow has no search field of its own (E1): a query left over from List would keep
        // filtering nothing here and sit invisibly until the user switched back — simpler to
        // drop it on entry than to grow a second place to show and clear it.
        .onAppear { flowFocused = true; model.searchText = ""; model.selectedIDs = [] }
        .onChange(of: model.scope) { _, _ in showAllOverride = false; focusedEdge = nil }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosViewOptionsRequested"))) { _ in
            showViewOptions = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIRequests.focusList)) { _ in
            flowFocused = true
        }
        .popover(isPresented: $showWaitsOnPicker) {
            if let id = model.selectedTaskID, let task = ctx.tasksByID[id] {
                FlowWaitsOnPicker(model: model, task: task) { showWaitsOnPicker = false }
            }
        }
        .popover(isPresented: $showHandoff) {
            if let id = model.selectedTaskID, let task = ctx.tasksByID[id] {
                FlowHandoffPicker(task: task, model: model, launchesHarness: handoffLaunchesHarness) { showHandoff = false }
            }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            move(press, ctx)
        }
        .onKeyPress(.return) { openSelected(ctx); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in removeFocusedEdge(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "wW")) { _ in
            guard model.selectedTaskID != nil else { return .ignored }
            showWaitsOnPicker = true
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "hH")) { press in
            guard model.selectedTaskID != nil else { return .ignored }
            handoffLaunchesHarness = (press.characters == "H")
            showHandoff = true
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "lL")) { _ in
            lanesMode.toggle()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent(".")]) { press in
            guard press.modifiers.contains(.command), let id = model.selectedTaskID else { return .ignored }
            stopRun(for: id, ctx)
            return .handled
        }
    }

    // MARK: - Context

    private func flowContext() -> FlowContext {
        let tasks = scopedTasks()
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let runStore = FlowRuns.store(model.store)
        let result = FlowLayout.build(tasks: tasks, activeRun: { runStore?.activeRun(taskID: $0) },
                                      today: today, cap: showAllOverride ? nil : 150)
        return FlowContext(tasks: tasks, tasksByID: tasksByID, result: result, runStore: runStore)
    }

    /// Open tasks in `model.scope`, plus tasks of that scope completed today (E2) — base
    /// project/area/saved-view membership reused from `ScopeFilter.matches`, "completed today"
    /// decided here so it never depends on any one fixed scope's own closed-task admission rule.
    private func scopedTasks() -> [KTask] {
        let today = self.today
        return model.store.allTasks().filter { t in
            if KStatus.open.contains(t.status) {
                return ScopeFilter.matches(t, scope: model.scope, today: today)
            }
            guard t.status == .done, let completedAt = t.completedAt, Day.from(completedAt) == today else { return false }
            return ScopeFilter.matches(t, scope: model.scope, today: today, includeClosed: true)
        }
    }

    // MARK: - Header

    private func header(_ ctx: FlowContext) -> some View {
        HStack(spacing: Space.x3) {
            HStack(spacing: Space.x2) {
                KViewMark(icon: scopeIcon, tint: Tok.textPrimary)
                Text(scopeTitle)
                    .font(Typo.display)
                    .tracking(Tracking.tight)
                    .foregroundStyle(Tok.textPrimary)
            }
            Spacer(minLength: Space.x4)
            if let capped = ctx.result.cappedTotal {
                Button(String(format: String(localized: "flow.showall"), capped)) { showAllOverride = true }
                    .kButton(.secondary)
                    .uiTestAnchor("flow.showall")
            }
            layoutControl
            KViewOptionsIconButton(activeCount: 0) { showViewOptions.toggle() }
                .popover(isPresented: $showViewOptions, arrowEdge: .bottom) {
                    ListViewOptionsPopoverContent(model: model, scope: model.scope)
                }
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.toolbarHeight)
    }

    /// List | Flow | Board, always visible — v1.2 person feedback (a): the sidebar's old
    /// dedicated "Flow" row made "All" permanently show Flow after one click with no visible
    /// way back (it set scope .all + that scope's layout .flow, then just stuck). This control
    /// writes the SAME per-scope `ViewOptions.layout` the view-options popover's own secondary
    /// `layoutRow` does (ListViewOptionsPopoverContent.swift) — one write, two doors — so
    /// where-you-are and how-to-leave are obvious from whichever of the three is on screen.
    private var layoutControl: some View {
        let binding = Binding<ListLayout>(
            get: { model.options(for: model.scope).layout },
            set: { var o = model.options(for: model.scope); o.layout = $0; model.setOptions(o, for: model.scope) }
        )
        return KSegmented(selection: binding, segments: [
            KSegment(value: ListLayout.list, icon: "list.bullet", text: String(localized: "viewoptions.layout.list")),
            KSegment(value: ListLayout.flow, icon: "point.3.connected.trianglepath.dotted", text: String(localized: "viewoptions.layout.flow"), hint: String(localized: "sidebar.help.flow")),
            KSegment(value: ListLayout.board, icon: "rectangle.split.3x1", text: String(localized: "viewoptions.layout.board")),
        ])
        .uiTestAnchor("header.layout.control")
    }

    private var scopeTitle: String {
        if let key = model.scope.titleKey { return String(localized: String.LocalizationValue(key)) }
        switch model.scope {
        case .project(let id): return model.store.allProjects().first { $0.id == id }?.name ?? ""
        case .area(let id): return model.store.allAreas().first { $0.id == id }?.name ?? ""
        case .savedView(let id): return model.store.allSavedViews().first { $0.id == id }?.name ?? ""
        default: return ""
        }
    }

    private var scopeIcon: String { model.scope.leadingIcon }

    /// "Blocked by 2 · unblocks 3" (E3) — only while a visible card is selected and has either
    /// chain; silent otherwise (no "Blocked by 0" noise, same rule the sidebar's counts follow).
    @ViewBuilder
    private func selectionHeader(_ ctx: FlowContext) -> some View {
        if let selected = model.selectedTaskID, ctx.visibleIDs.contains(selected) {
            let up = FlowLayout.upstream(of: selected, edges: ctx.result.edges).count
            let down = FlowLayout.downstream(of: selected, edges: ctx.result.edges).count
            if up > 0 || down > 0 {
                Text(chainText(blockedBy: up, unblocks: down))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x1)
                    .uiTestAnchor("flow.selection.chain")
            }
        }
    }

    private func chainText(blockedBy: Int, unblocks: Int) -> String {
        var parts: [String] = []
        if blockedBy > 0 {
            parts.append(KPlural.hr(blockedBy, one: String(localized: "flow.blockedby.one"),
                                    few: String(localized: "flow.blockedby.few"),
                                    many: String(localized: "flow.blockedby.many")))
        }
        if unblocks > 0 {
            parts.append(KPlural.hr(unblocks, one: String(localized: "flow.unblocks.one"),
                                    few: String(localized: "flow.unblocks.few"),
                                    many: String(localized: "flow.unblocks.many")))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ ctx: FlowContext) -> some View {
        if ctx.visibleIDs.isEmpty {
            KEmptyState(icon: "hourglass", title: String(localized: "flow.empty.title"),
                       message: String(localized: "flow.empty.message"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lanesMode {
            FlowLanesView(model: model, tasksByID: ctx.tasksByID, visibleIDs: ctx.visibleIDs, runStore: ctx.runStore,
                         focusedID: model.selectedTaskID, highlighted: highlightedIDs(ctx), gateIDs: ctx.gateIDs,
                         onSelect: { select($0) })
        } else {
            FlowColumnsView(model: model, result: ctx.result, tasksByID: ctx.tasksByID, runStore: ctx.runStore,
                            focusedID: model.selectedTaskID, highlighted: highlightedIDs(ctx), gateIDs: ctx.gateIDs,
                            headerText: columnHeaderText, onSelect: { select($0) })
        }
    }

    private func columnHeaderText(_ column: FlowLayout.Column) -> String {
        let word: String
        switch column.depth {
        case 0: word = String(localized: "flow.column.canstart")
        case 1: word = String(localized: "flow.column.next")
        default: word = String(localized: "flow.column.later")
        }
        return "\(word) · \(column.taskIDs.count)"
    }

    /// Selected id plus its full upstream/downstream chain — everything else dims (E3).
    private func highlightedIDs(_ ctx: FlowContext) -> Set<UUID> {
        guard let selected = model.selectedTaskID, ctx.visibleIDs.contains(selected) else { return [] }
        var set = FlowLayout.upstream(of: selected, edges: ctx.result.edges)
        set.formUnion(FlowLayout.downstream(of: selected, edges: ctx.result.edges))
        set.insert(selected)
        return set
    }

    // MARK: - Selection (shared with the inspector pane, matching the list's own row click)

    /// Same write `TaskListScreen+Bulk.swift`'s `handleRowClick` makes for a plain row click:
    /// drop any multi-selection and set the anchor directly — NOT `openDetails(taskID:)`, which
    /// is for subtask-aware access points (ⓘ, palette, double-click) that redirect a child's
    /// click onto its parent. A plain card click is a plain select, exactly like a list row;
    /// Return still calls `openDetails` (FlowScreen+Keys.swift's `openSelected`), matching the
    /// list's own Return (`TaskListScreen+Keys.swift`'s `selectAndOpen`).
    func select(_ id: UUID) {
        focusedEdge = nil
        model.selectedIDs = []
        model.selectedTaskID = id
    }
}
