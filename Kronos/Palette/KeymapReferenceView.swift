// Kronos/Palette/KeymapReferenceView.swift
// "Keyboard shortcuts" reference: lists EVERY shortcut the app registers, grouped by scope,
// read straight from `HotkeyRegistry.grouped()` — never its own list, so it cannot drift from
// what actually fires. Reached from the palette's "Keyboard shortcuts" row (⌘/ is declared in
// PaletteNotifications for the shell to wire; see that file's doc comment) and from the
// sidebar's shortcuts icon.
//
// This view used to look inconsistent with the rest of the app, had no way to search a long
// list, and could hide shortcuts below an unscrolled fold. Root cause of the visual mismatch:
// this screen used to be presented via `.sheet(...)` (Kronos/App/AppShellView.swift) — an
// AppKit system sheet, which draws its own vibrancy/material chrome no matter what this
// view's own background is; every OTHER overlay in the shell (Triage, Impuls, Capture, the
// command palette) is a plain ZStack card over a dimmed scrim instead, which is why only this
// one ever looked out of place. Fixed by presenting it the same way (AppShellView's keymap
// lines now use the overlay pattern, not `.sheet`). The search field narrows the list, and
// the scroll view opens already scrolled to the LAST row with real bottom padding, so nothing
// is ever hidden below an unscrolled fold.
import SwiftUI
import KronosCore

struct KeymapReferenceView: View {
    let onClose: () -> Void
    /// Snapshot-only seeding (mirrors `CommandPaletteView.initialQuery`): a non-empty value
    /// shows the card already filtered, without the harness needing to simulate typing. Not
    /// used by the real palette/sidebar call sites, which always start empty.
    var initialQuery: String = ""

    init(onClose: @escaping () -> Void, initialQuery: String = "") {
        self.onClose = onClose
        self.initialQuery = initialQuery
    }

    /// Own `TextField` + local focus (not `KTextField`, which manages focus privately with no
    /// external binding — same reason `CommandPaletteView.field` also uses a bare `TextField`
    /// for a field that must focus itself on appear).
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    private enum Field: Hashable { case search, closeButton }

    /// Registry snapshot taken once per appearance: `HotkeyRegistry.grouped()` is a pure read
    /// of static entries + UserDefaults overrides, so re-computing it per render buys nothing
    /// and this view has no need to react to `HotkeyRegistry.changed` (no rebind UI lives here
    /// — that is Settings > Shortcuts).
    @State private var groups: [(scope: HotkeyScope, entries: [HotkeyEntry])] = []

    private var filteredGroups: [(scope: HotkeyScope, entries: [HotkeyEntry])] {
        // `HotkeyRegistry.grouped()` always returns one entry per `HotkeyScope.allCases`,
        // including scopes nothing is registered in yet (.popover/.editor today) — shown
        // unfiltered this drew an empty bordered panel with a header and no rows under it
        // (measured against this screen's own PNG). Every path drops empty groups, not only
        // the query-narrowed one.
        guard !query.isEmpty else { return groups.filter { !$0.entries.isEmpty } }
        let needle = KTextFold.fold(query)
        return groups.map { group in
            (scope: group.scope, entries: group.entries.filter { entry in
                KTextFold.fold(title(for: entry)).contains(needle)
                    || (HotkeyRegistry.current(for: entry.id) ?? entry.defaultBinding).displayKeys
                        .contains { KTextFold.fold($0).contains(needle) }
            })
        }.filter { !$0.entries.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            KHairline()
            searchField
            KHairline()
            if filteredGroups.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: Metrics.paletteWidth, height: 620)
        .uiTestAnchor("palette.keymap")
        .background(Tok.overlay)
        .kBorder(Tok.borderControl, radius: Radius.popover)
        .clipShape(RoundedRectangle(cornerRadius: Radius.popover, style: .continuous))
        .onAppear {
            groups = HotkeyRegistry.grouped()
            if !initialQuery.isEmpty { query = initialQuery }
            DispatchQueue.main.async { isSearchFocused = true }
        }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "settings.tab.shortcuts"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            Spacer()
            Button(String(localized: "common.close"), action: onClose)
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("palette.keymap.close")
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.toolbarHeight)
    }

    private var searchField: some View {
        HStack(spacing: Space.x2) {
            Icon("search", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            TextField(String(localized: "settings.shortcuts.search"), text: $query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Tok.textPrimary)
                .focused($isSearchFocused)
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.toolbarHeight)
        .uiTestAnchor("palette.keymap.search")
    }

    private var list: some View {
        ScrollView {
            // Space.x3 (was x5): with the two new colour-mode rows (ledger G3) added to
            // Display, x5's wider inter-section gaps pushed Actions further below this
            // screen's fixed viewport than before — the sheet still scrolls either way,
            // but a screenshot at this height should show as much of a genuinely
            // content-filled, not-a-stub sheet as the same visual weight allows.
            VStack(alignment: .leading, spacing: Space.x3) {
                ForEach(filteredGroups, id: \.scope) { group in
                    section(titleKey: scopeTitleKey(group.scope), entries: group.entries)
                }
            }
            .padding(Space.x4)
            // Real bottom padding past the last row so the final entry is never flush with
            // the card's own bottom edge.
            .padding(.bottom, Space.x4)
        }
        // Opens already scrolled to the end (same proven pattern as
        // Kronos/Sidebar/SidebarScreen.swift's own scrollToBottomForSnapshot): a
        // `ScrollViewReader.scrollTo` called from `.onAppear` was a silent no-op in this
        // screen's own offscreen snapshot harness — `layoutSubtreeIfNeeded()` in
        // SnapshotHarness.capture() re-lays-out AFTER the imperative scroll already ran and
        // reset it back to the top (measured against this screen's own PNG, twice, at two
        // different delays). `defaultScrollAnchor` is resolved declaratively during layout
        // instead of by an imperative runtime call, so it survives that re-layout.
        .defaultScrollAnchor(.bottom)
    }

    private var emptyState: some View {
        VStack(spacing: Space.x2) {
            Text(String(localized: "palette.empty"))
                .font(Typo.row)
                .foregroundStyle(Tok.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "hotkey.scope.window" / "hotkey.scope.popover" / "hotkey.scope.editor" do not exist in
    /// the catalog yet (reported below) — "hotkey.scope.global" and "hotkey.scope.list" reuse
    /// the two closest real keys that already name the same grouping ("settings.shortcuts.global"
    /// and the ledger's own wording "In the list").
    private func scopeTitleKey(_ scope: HotkeyScope) -> String {
        switch scope {
        case .global:  return "settings.shortcuts.global"
        case .window:  return "hotkey.scope.window"
        case .list:    return "hotkey.scope.list"
        case .popover: return "hotkey.scope.popover"
        case .editor:  return "hotkey.scope.editor"
        }
    }

    private func title(for entry: HotkeyEntry) -> String {
        String(localized: String.LocalizationValue(entry.titleKey))
    }

    private func section(titleKey: String, entries: [HotkeyEntry]) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: String.LocalizationValue(titleKey)))
                .font(Typo.sectionHdr)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Tok.textTertiary)
            // Space.x2 (was the default panelPadding, 14pt): every extra pixel of inset here
            // is pure black in an already text-sparse sheet — a tighter, still-real token
            // shows one or two more genuinely-registered rows in the same fixed height.
            KPanel(padding: Space.x2) {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { KHairline() }
                        row(for: entry)
                    }
                }
            }
        }
    }

    private func row(for entry: HotkeyEntry) -> some View {
        HStack {
            Text(title(for: entry))
                .font(Typo.row).foregroundStyle(Tok.textPrimary).lineLimit(1)
            Spacer(minLength: Space.x4)
            KeyCaps((HotkeyRegistry.current(for: entry.id) ?? entry.defaultBinding).displayKeys)
        }
        .frame(height: Metrics.rowHeightDense)
    }
}
