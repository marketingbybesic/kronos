// Kronos/List/ListGroupedSections.swift
// Renders TaskListScreen's main run as sticky "Group by" sections (spec §4.6) instead of one
// flat `ForEach`, when the view's options ask for it (TaskListScreen.swift branches on
// `ctx.options.groupBy`). Follows the ListMissingGroup/ListEarlierSection pattern: a shared
// `@Observable` holds which groups are folded, keyed by scope + mode + group so every reader of
// the list (and a later re-open of the same scope) agrees on what was collapsed.
import SwiftUI
import KronosCore

/// Which groups are collapsed, per scope + "Group by" mode + group key, in one session-shared
/// store — like ListMissingState/ListEarlierState, every reader of the list must agree. Starts
/// with nothing folded, then whatever was still folded last launch: the internal notes
/// §4.6 (line 523) asks for `collapsed.<viewID>` → `Set<String>`, one UserDefaults key per view;
/// this keeps the app's own richer composite key instead — `scope|mode|groupKey` (`stateKey`
/// below, already needed so two different "Group by" modes on the same scope never collide) — in
/// ONE `Set<String>` under ONE UserDefaults key, hermetic under KRONOS_SNAPSHOT like every other
/// controller in this codebase (Kronos/DesignSystem/AppearancePrefs.swift).
@MainActor
@Observable
final class ListGroupingState {
    static let shared = ListGroupingState()
    private static let defaultsKey = "kronos.list.grouping.collapsed"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .snapshotScratch : .standard
    }

    /// Loaded once, from the singleton's own lazy creation — there is no earlier point at which
    /// reading it would mean anything.
    private var collapsedKeys: Set<String>
    /// Bumped on every `toggle`, and read into `ListContextKey` (ListContext.swift) so a
    /// collapse/expand busts the list's one-entry memo immediately — the same mechanism
    /// ListMissingState/ListEarlierState's `isExpanded` already relies on — instead of leaving
    /// `ctx.displayRows` (the keyboard's walking order) stale until an unrelated write also
    /// happens to bump `model.version`.
    private(set) var generation = 0

    private init() {
        collapsedKeys = Set(Self.defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    private func stateKey(_ scope: ListScope, _ mode: KGroupBy, _ groupKey: String) -> String {
        "\(scope.storageKey)|\(mode.rawValue)|\(groupKey)"
    }

    func isCollapsed(_ scope: ListScope, _ mode: KGroupBy, _ groupKey: String) -> Bool {
        collapsedKeys.contains(stateKey(scope, mode, groupKey))
    }

    func toggle(_ scope: ListScope, _ mode: KGroupBy, _ groupKey: String) {
        let key = stateKey(scope, mode, groupKey)
        if collapsedKeys.contains(key) { collapsedKeys.remove(key) } else { collapsedKeys.insert(key) }
        generation &+= 1
        Self.defaults.set(Array(collapsedKeys), forKey: Self.defaultsKey)
    }
}

private extension UserDefaults {
    /// One throwaway suite per snapshot process — never the real `kronos.list.grouping.*` key
    /// during a gate run, matching AppearancePrefs' own `.snapshotScratch`.
    static let snapshotScratch = UserDefaults(suiteName: "kronos.snapshot.grouping." + UUID().uuidString) ?? .standard
}

extension TaskListScreen {
    /// The main run: the flat `ForEach` TaskListScreen always rendered, or "Group by"'s sticky
    /// sections in its place (spec §4.6) when `ctx.options.groupBy` asks for one — the SAME rows
    /// either way, just drawn differently; `ctx.rows`/`currentRows` stay the flat, already-sorted
    /// sequence. Keyboard navigation (TaskListScreen+Keys.swift) and the post-complete/delete
    /// neighbour (ListCompletion.swift) instead walk `ctx.displayRows`, which follows THIS
    /// grouped-and-collapsed order rather than the flat one (review finding 2) — both it and this
    /// view read `ctx.groupedSections`, the one partition `ListContext` computed, so the two can
    /// never disagree. The missing-value and Earlier sections (TaskListScreen.swift) keep their
    /// own placement around this call either way — grouping only ever touches the main run.
    @ViewBuilder
    func mainRows(_ ctx: ListContext, _ columnMode: ColumnMode) -> some View {
        if ctx.options.groupBy == .none {
            ForEach(ctx.currentRows, id: \.id) { task in
                row(task, ctx, columnMode)
            }
        } else {
            groupedMainSections(ctx, columnMode)
        }
    }

    /// One sticky `GroupHeader` + its rows per `ctx.groupedSections` — the partition `ListContext`
    /// already computed once for this build (`ListGrouping.sections`). Reading it here, rather
    /// than calling `ListGrouping.sections` again, keeps this view and `ctx.displayRows`'s
    /// keyboard-walking order looking at the exact same groups.
    @ViewBuilder
    private func groupedMainSections(_ ctx: ListContext, _ columnMode: ColumnMode) -> some View {
        let mode = ctx.options.groupBy
        ForEach(ctx.groupedSections) { section in
            let isCollapsed = ListGroupingState.shared.isCollapsed(model.scope, mode, section.key)
            Section {
                if !isCollapsed {
                    ForEach(section.rows, id: \.id) { task in
                        row(task, ctx, columnMode)
                    }
                }
            } header: {
                GroupHeader(title: section.title, leading: leadingMark(section.leading),
                           count: section.rows.count, isCollapsed: isCollapsed, onToggle: {
                    withAnimation(Motion.curve(Motion.fast)) {
                        ListGroupingState.shared.toggle(model.scope, mode, section.key)
                    }
                }, anchor: "list.group.header.\(section.key)")
                    .padding(.top, Space.x2)
            }
        }
    }

    private func leadingMark(_ leading: ListGrouping.GroupLeading) -> KSidebarRow.Leading {
        switch leading {
        case .none:
            return .none
        case .projectColor(let hex):
            let neutral = model.chromaMode.isNeutralSelection
            return .dot(SelectionHue.resolve(projectHex: hex, neutral: neutral).color(accent: accent))
        case .priorityLevel(let level):
            return .dot(priorityDotColor(level))
        }
    }

    /// Same tones as `PriorityGlyph` (DesignSystem/PriorityGlyph.swift) — priority is the one
    /// deliberate colour exception in this app's otherwise monochrome chrome.
    private func priorityDotColor(_ level: Int) -> Color {
        switch level {
        case 1: return Tok.prioLow
        case 2: return Tok.prioMedium
        case 3: return Tok.prioHigh
        case 4: return Tok.prioUrgent
        default: return Tok.prioNone
        }
    }
}
