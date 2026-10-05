// Kronos/Sidebar/SidebarScreen.swift
// The sidebar: fixed scopes, areas with nested projects (each with its saved views), the slim list of views
// that belong to no project, archived projects.
// Both display modes (icons-only rail / icons+text) via KSidebarRow/KSectionHeader, which
// read the display mode from `\.kSidebarMode` set by the app shell. Selection = `model.scope`;
// arrow keys move it.
//
// Core rev 4 closed the gaps a previous revision of this file had to report: `allAreas()`
// now surfaces areas with zero projects, and create/rename/archive/restore/move all exist.
// Saved views and the archived-projects list live in their own files (SidebarSavedViews.swift,
// SidebarArchived.swift) so this one stays under the line-count gate.
import SwiftUI
import KronosCore

struct SidebarScreen: View {
    let model: AppModel
    /// Snapshot-only: forces the Archived disclosure open so `sidebar.archived` always
    /// renders expanded regardless of the (per-window, non-persisted) toggle state.
    private let archivedExpandedForSnapshot: Bool
    /// Snapshot-only: on the real 37-task seed, both Saved Views and Archived sit below the
    /// fold of a 760pt-tall sidebar, so a screen meant to show one would be indistinguishable
    /// from a plain "sidebar" shot without this.
    private let scrollToBottomForSnapshot: Bool

    @State private var expandedAreaIDs: Set<UUID>?
    // Not `private`: SidebarScreen+AreaAdd.swift's extension (the Area row's hover "+") sets it.
    @State var editorTarget: EditorTarget?
    @State private var areaEditorTarget: AreaEditorTarget?
    @State private var isArchivedExpanded = false
    /// Which project row (if any) a drag it accepts (a task row, a Finder folder) is currently
    /// over, for the hairline highlight. At most one row at a time.
    @State private var dropTargetProjectID: UUID?
    /// Which Area row (if any) the mouse is over, for the hover-revealed "+" (see
    /// SidebarScreen+AreaAdd.swift — moved there to keep this file under the line gate).
    @State var hoveredAreaID: UUID?

    init(model: AppModel, archivedExpandedForSnapshot: Bool = false, scrollToBottomForSnapshot: Bool = false) {
        self.model = model
        self.archivedExpandedForSnapshot = archivedExpandedForSnapshot
        self.scrollToBottomForSnapshot = scrollToBottomForSnapshot
    }

    private var currentSidebarWidth: CGFloat {
        model.sidebarIconsOnly ? Metrics.sidebarRail : Metrics.sidebarDefault
    }

    /// Areas start expanded — a fresh sidebar with everything collapsed hides most of the
    /// workspace behind a click. `nil` means "not yet initialised for this data"; the first
    /// body evaluation seeds it from whatever areas exist so a later-created area also
    /// starts open rather than being silently absent from the set.
    private func expanded(_ id: UUID) -> Bool { (expandedAreaIDs ?? Set(areas.map(\.id))).contains(id) }

    struct EditorTarget: Identifiable {
        let id = UUID()
        let mode: SidebarProjectEditor.Mode
    }

    struct AreaEditorTarget: Identifiable {
        let id = UUID()
        let mode: SidebarAreaEditor.Mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clears the fixed traffic-light hit zone in BOTH modes — the window has no
            // title bar (KronosApp: .hiddenTitleBar), so the sidebar's own top inset is
            // the only thing standing between the lights and the first row. The lights sit
            // in AppKit's ~28pt title-bar band regardless of window width, so a vertical
            // inset alone clears them in the rail too — their ~78pt HORIZONTAL span only
            // matters if content shared their row, which nothing here does.
            Color.clear.frame(height: Metrics.sidebarOuterInset + 20)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sidebarRowVGap) {
                    fixedScopesSection
                        .tourAnchor(.sidebarLists)
                    areasSection
                    SidebarSavedViewsSection(model: model)
                    SidebarArchivedSection(model: model,
                                            isExpanded: archivedExpandedForSnapshot || isArchivedExpanded,
                                            onToggle: { isArchivedExpanded.toggle() })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.sidebarOuterInset)
            }
            // Declarative (content-driven) rather than a timed `ScrollViewReader.scrollTo`,
            // which raced the seed's `.onAppear` and settled short.
            .defaultScrollAnchor(scrollToBottomForSnapshot ? .bottom : .top)

            Spacer(minLength: 0)
            KHairline()
            footer
                .tourAnchor(.sidebarPower)
        }
        // A VStack sizes to its widest child's IDEAL width, and `.frame(maxWidth: .infinity)`
        // on a row only expands to whatever width the parent already decided to offer — it
        // does not itself push the parent wider. The footer's HStack (mode toggle + settings
        // button, no flexible child) has a narrower ideal width than a full row, so without
        // this it becomes the narrowest well-defined width in the tree and the WHOLE sidebar
        // (rows included, selection bar clipped in the process) collapses to roughly that
        // width in icons-only mode. Pinning the outer VStack itself is what forces every
        // sibling — ScrollView content and footer alike — to resolve within the real sidebar
        // width (found by bisecting the view tree against a debug probe screen: removing the
        // footer alone made the rows render at full width again).
        .frame(width: currentSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Tok.bg)
        // Set from the model directly (not inherited) so this screen is correct both when
        // hosted by AppShellView and when rendered standalone by the snapshot harness.
        .environment(\.kSidebarMode, model.sidebarIconsOnly ? .iconsOnly : .iconsAndText)
        .onMoveCommand(perform: moveSelection)
        .popover(item: $editorTarget) { target in
            SidebarProjectEditor(model: model, mode: target.mode, areas: areas) {
                editorTarget = nil
            }
        }
        .popover(item: $areaEditorTarget) { target in
            SidebarAreaEditor(model: model, mode: target.mode) {
                areaEditorTarget = nil
            }
        }
    }

    // MARK: Fixed scopes

    private var fixedScopesSection: some View {
        VStack(alignment: .leading, spacing: Metrics.sidebarRowVGap) {
            ForEach(ListScope.fixed, id: \.self) { scope in
                row(for: scope)
            }
        }
    }

    private func row(for scope: ListScope) -> some View {
        let key = scope.titleKey ?? "sidebar.inbox"
        return KSidebarRow(title: String(localized: String.LocalizationValue(key)),
                            leadingIcon: icon(for: scope),
                            count: Self.showsCount(for: scope) ? nilIfZero(count(for: scope)) : nil,
                            isSelected: model.scope == scope) {
            select(scope)
        }
        .kTooltip(rowTooltip(scopeHelp(scope)))
    }

    /// One short gloss per fixed list (shown as the row's tooltip).
    private func scopeHelp(_ scope: ListScope) -> String {
        switch scope {
        case .inbox: String(localized: "sidebar.help.inbox")
        case .today: String(localized: "sidebar.help.today")
        case .next7: String(localized: "sidebar.help.next7")
        case .waiting: String(localized: "sidebar.help.waiting")
        case .someday: String(localized: "sidebar.help.someday")
        case .all: String(localized: "sidebar.help.all")
        case .project, .area, .savedView: ""
        }
    }

    /// KSidebarRow renders a literal "0" as "—", which reads as a pressure/failure signal
    /// (ledger fix) — passing nil instead keeps the trailing slot's width reserved (so rows
    /// don't jump when a count later appears) but shows nothing where "—" would have been.
    private func nilIfZero(_ n: Int) -> Int? { n == 0 ? nil : n }

    private func icon(for scope: ListScope) -> String {
        scope.leadingIcon   // one table, shared with the list header (SelectionHue+Color.swift)
    }

    // MARK: Areas + projects

    /// Every area in manual order (rev 4 `allAreas()` — includes areas with zero projects).
    private var areas: [KArea] { model.store.allAreas() }

    private var projectsWithoutArea: [KProject] {
        model.store.allProjects().filter { $0.area == nil }
    }

    private var areasSection: some View {
        // Reading `model.version` here (unused otherwise) makes @Observable re-evaluate this
        // computed property — and therefore `areas`/counts below — on every store mutation.
        let _ = model.version
        // One fetch for every project's views (each is drawn under the project it belongs to).
        var viewsByProject: [UUID: [KSavedView]] = [:]
        for view in model.store.allSavedViews() {
            if let home = view.homeProjectID { viewsByProject[home, default: []].append(view) }
        }
        return Group {
            KSectionHeader(String(localized: "sidebar.section.areas"), trailingIcon: "plus",
                           trailingLabel: String(localized: "sidebar.add.area"),
                           alwaysVisibleWhenEmpty: areas.isEmpty) {
                areaEditorTarget = AreaEditorTarget(mode: .create)
            }
            .uiTestAnchor("sidebar.areas.add")
            ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                areaRow(area, index: index)
                if expanded(area.id) {
                    ForEach(area.orderedProjects.filter { !$0.isArchived }) { project in
                        projectRow(project, indent: 1)
                        SidebarProjectViewRows(model: model, views: viewsByProject[project.id] ?? [], indent: 2, tasks: cachedTasks)
                    }
                }
            }
            if !projectsWithoutArea.isEmpty || !areas.isEmpty {
                // Same "+ to add a project" rule applied to the flat (no-area) project group:
                // a header only shows up once there is something to anchor it to (an area
                // exists) or a project is already unassigned, matching areasSection's own
                // "hidden once non-empty, but never entirely absent" shape.
                KSectionHeader(String(localized: "sidebar.section.projects"), trailingIcon: "plus",
                               trailingLabel: String(localized: "sidebar.add.project"),
                               alwaysVisibleWhenEmpty: projectsWithoutArea.isEmpty) {
                    editorTarget = EditorTarget(mode: .create(area: nil))
                }
                .uiTestAnchor("sidebar.projects.add")
            }
            ForEach(projectsWithoutArea) { project in
                projectRow(project, indent: 0)
                SidebarProjectViewRows(model: model, views: viewsByProject[project.id] ?? [], indent: 1, tasks: cachedTasks)
            }
        }
    }

    /// Direction F: areas are a quiet disclosure row — a chevron, no icon, no count (the
    /// area's own weight comes from the projects nested under it, not a number of its own).
    private func areaRow(_ area: KArea, index: Int) -> some View {
        let isExpanded = expanded(area.id)
        return KSidebarRow(title: area.name, isExpanded: isExpanded,
                            isSelected: model.scope == .area(area.id)) {
            // One click, one handler: a tap gesture stacked on the row's Button raced it.
            select(.area(area.id))
            toggleExpanded(area.id)
        }
        // A "+" on hover over an Area row creates a project IN that area, name field focused
        // for typing. `KSidebarRow` has no trailing-accessory slot, so
        // the same hover-opacity `KSectionHeader.trailingButton` pattern is reproduced here
        // directly rather than growing the row component for one caller. Hover tracked on
        // the whole row (not just the button) — a zero-opacity button is still hit-testable,
        // but nothing would ever set its opacity to 1 without first hovering it.
        .overlay(alignment: .trailing) {
            if !model.sidebarIconsOnly {
                areaAddProjectButton(area, index: index, visible: hoveredAreaID == area.id)
            }
        }
        .onHover { hovering in hoveredAreaID = hovering ? area.id : (hoveredAreaID == area.id ? nil : hoveredAreaID) }
        .accessibilityLabel(Text(verbatim: area.name))
        .help(model.sidebarIconsOnly ? area.name : "")
        .contextMenu {
            Button(String(localized: "ctx.area.newproject")) {
                editorTarget = EditorTarget(mode: .create(area: area))
            }
            Button(String(localized: "ctx.area.rename")) {
                areaEditorTarget = AreaEditorTarget(mode: .edit(area))
            }
            Divider()
            Button(String(localized: "sidebar.area.delete")) { deleteArea(area) }
        }
    }


    /// `isFocus`: exactly one project row carries hue in Focus mode — the project of
    /// `model.focusTaskID`'s task, re-evaluated on `model.version` (task moved/completed) and
    /// whenever the pin/Ordo focus changes.
    private func projectRow(_ project: KProject, indent: Int) -> some View {
        let _ = model.version
        let isFocus = model.focusTaskID.flatMap(model.store.task)?.projectID == project.id
        let isDropTarget = dropTargetProjectID == project.id
        return KSidebarRow(title: project.name,
                    projectIcon: project.icon,
                    colorHex: project.colorHex,
                    isFocus: isFocus,
                    indent: indent,
                    isSelected: model.scope == .project(project.id)) {
            select(.project(project.id))
        }
        // The quiet "context folders exist" hint (ledger: a small mapped glyph at the
        // tertiary tone, no badge, no count). Calm mode was removed in rev18; the glyph
        // now shows whenever the sidebar is in icons-and-text mode.
        .overlay(alignment: .trailing) {
            if hasLinkedFolders(project), !model.sidebarIconsOnly {
                Icon("folder", size: Metrics.iconS)
                    .foregroundStyle(Tok.textDisabled)
                    .padding(.trailing, Metrics.sidebarRowTrailing + Space.x4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Drop highlight: a hairline only (ledger G9), NOT `KSidebarRow.isDropTarget` — that
        // shared style also paints `Tok.dropFill`, which the brief explicitly rules out here.
        // Drawn as a plain stroked overlay instead, so the row's own fill/selection state is
        // untouched by a drag passing over it.
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Tok.textPrimary, lineWidth: Metrics.strokeHair)
            }
        }
        // Drops on a project: a task row dragged out of the list files the task here (one undo
        // step, the usual pill); a Finder directory links as a context folder; a plain file, a
        // Notes drag or anything else is refused, so the row never lights up for it. Notes-folder
        // drags are undocumented and are linked via the editor's picker instead.
        .onDrop(of: SidebarProjectDropDelegate.types,
                delegate: SidebarProjectDropDelegate(projectID: project.id, model: model, targetID: $dropTargetProjectID))
        .contextMenu {
            Button(String(localized: "ctx.area.rename")) {
                editorTarget = EditorTarget(mode: .rename(project))
            }
            Menu(String(localized: "ctx.project.movearea")) {
                Button(String(localized: "sidebar.noarea")) {
                    model.store.moveProject(project.id, toArea: nil)
                    model.didMutate()
                }
                ForEach(areas) { area in
                    Button(area.name) {
                        model.store.moveProject(project.id, toArea: area)
                        model.didMutate()
                    }
                }
            }
            Divider()
            projectFolderMenuItems(project)
            Button(String(localized: "ctx.area.archive")) { archiveProject(project) }
        }
    }


    private func toggleExpanded(_ id: UUID) {
        withAnimation(Motion.curve(Motion.fast)) {
            var set = expandedAreaIDs ?? Set(areas.map(\.id))
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            expandedAreaIDs = set
        }
    }

    // MARK: Footer

    /// An icon that opens the full keyboard-shortcuts reference on click.
    private var keymapButton: some View {
        Button {
            NotificationCenter.default.post(name: .kronosKeymapRequested, object: nil)
        } label: {
            Icon("keyboard", size: Metrics.iconM)
        }
        .kButton(.icon)
        .accessibilityLabel(String(localized: "sidebar.shortcuts"))
        .help(String(localized: "sidebar.help.shortcuts"))
    }

    private var settingsButton: some View {
        Button {
            NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil)
        } label: {
            Icon("settings", size: Metrics.iconM)
        }
        .kButton(.icon)
        .accessibilityLabel(String(localized: "sidebar.settings"))
        .help(String(localized: "sidebar.help.settings"))
    }

    private var footer: some View {
        VStack(spacing: Metrics.sidebarRowVGap) {
            // Only shown once Time Blocks is turned on in Settings > Coach
            // (TimeBlocksPrefs.isEnabled, off by default — a new surface, not a replacement
            // for the existing lists).
            if TimeBlocksPrefs.isEnabled {
                KSidebarRow(title: String(localized: "timeblocks.title"), leadingIcon: "calendar") {
                    model.isTimeBlocksOpen = true
                }
                .kTooltip(rowTooltip(String(localized: "sidebar.help.timeblocks")))
            }
            // Only while agents have something waiting: a standing "Review" row would be a second
            // inbox to keep at zero.
            if reviewCount > 0 {
                KSidebarRow(title: String(localized: "review.sidebar.title"), leadingIcon: "eye", count: reviewCount) {
                    TriageLaunch.shared.request(.review)
                    model.isTriageOpen = true
                }
                .kTooltip(rowTooltip(String(localized: "sidebar.help.review")))
                .uiTestAnchor("sidebar.review")
            }
            // The two session rows carry their shortcut as quiet text at the right edge.
            KSidebarRow(title: String(localized: "menu.task.triage"), leadingIcon: "check-square") {
                model.isTriageOpen = true
            }
            .overlay(alignment: .trailing) { shortcutHint(forEntry: "window.triage") }
            .kTooltip(rowTooltip(String(localized: "sidebar.help.sort")))
            KSidebarRow(title: String(localized: "sidebar.impuls"), leadingIcon: "zap") {
                model.isImpulsOpen = true
            }
            .overlay(alignment: .trailing) { shortcutHint(forEntry: "window.impuls") }
            .kTooltip(rowTooltip(String(localized: "sidebar.help.pickone")))
            if model.sidebarIconsOnly {
                // The colour mode is a setting (Settings > Appearance), not a footer action.
                settingsButton
                Button {
                    model.sidebarIconsOnly = false
                    model.persist()
                } label: {
                    Icon("panel-right", size: Metrics.iconM)
                }
                .kButton(.icon)
                .accessibilityLabel(String(localized: "sidebar.mode.full"))
                .help(String(localized: "sidebar.help.mode.full"))
            } else {
                // One aligned row instead of two stacked ones, which used to read as
                // leftovers: keyboard, settings, then collapse LAST — the
                // hide-sidebar icon belongs all the way to the right, not at the start.
                HStack(spacing: Space.x1) {
                    Spacer(minLength: Space.x2)
                    keymapButton
                    settingsButton
                    Button {
                        model.sidebarIconsOnly = true
                        model.persist()
                    } label: {
                        Icon("panel-right", size: Metrics.iconM)
                    }
                    .kButton(.icon)
                    .accessibilityLabel(String(localized: "sidebar.mode.icons"))
                    .help(String(localized: "sidebar.help.mode.icons"))
                }
            }
        }
        .padding(Metrics.sidebarOuterInset)
    }

    // MARK: Selection + counts

    private func select(_ scope: ListScope) {
        model.scope = scope
        model.persist()
    }

    /// One store fetch per (store version, day) instead of one per row per render: the three
    /// count helpers used to run `allTasks().filter` for every sidebar row on every body pass.
    /// A reference type in @State: filling it during render does not invalidate the view.
    private final class CountCache {
        var key = ""
        var tasks: [KTask] = []
        var scopes: [ListScope: Int] = [:]
    }
    @State private var countCache = CountCache()

    private var cachedTasks: [KTask] {
        let today = Day.today()
        let key = "\(model.version)|\(today)"
        if countCache.key != key {
            countCache.key = key
            countCache.tasks = model.store.allTasks()
            countCache.scopes = [:]
        }
        return countCache.tasks
    }

    /// Proposals and agent results waiting for a decision (not the ones put off until tomorrow).
    private var reviewCount: Int {
        ReviewQueue.count(in: cachedTasks, snoozed: ReviewSnooze.table, today: Day.today(calendar: KronosLocale.calendar))
    }

    private func count(for scope: ListScope) -> Int {
        let tasks = cachedTasks
        if let hit = countCache.scopes[scope] { return hit }
        let today = Day.today()
        let n = tasks.filter { ScopeFilter.countsInSidebar($0, scope: scope, today: today) }.count
        countCache.scopes[scope] = n
        return n
    }

    /// A calm sidebar: only Inbox and Today carry a number (what is waiting to be sorted and what is
    /// due now). Every other scope, project and the Sort row stay silent, so no list reads as a
    /// backlog to clear.
    static func showsCount(for scope: ListScope) -> Bool {
        scope == .inbox || scope == .today
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let all = ListScope.fixed
        guard let current = all.firstIndex(of: model.scope) else { select(all[0]); return }
        switch direction {
        case .up:   select(all[max(0, current - 1)])
        case .down: select(all[min(all.count - 1, current + 1)])
        default: break
        }
    }
}
