// Kronos/Sidebar/SidebarScreen+Actions.swift
// Context-menu actions of the sidebar and the small pieces that decorate its rows. Out of
// SidebarScreen.swift to keep that file under the line gate; the store writes themselves live in
// SidebarStoreActions.swift. The menu actions are static so the live test runs the very code the
// menus call.
import SwiftUI
import KronosCore

@MainActor
enum SidebarMenuActions {
    /// Archive from a project's menu: its open tasks leave every list but the project's own, the
    /// pill says so and offers Undo. Leaves the project's own list for Today first, so the view
    /// that was just archived is not the one left on screen.
    static func archiveProject(_ project: KProject, model: AppModel) {
        guard let outcome = SidebarStoreActions.archiveProject(project.id, store: model.store) else { return }
        if model.scope == .project(project.id) {
            model.scope = .today
            model.persist()
        }
        model.didMutate()
        UndoToastCenter.shared.show(SidebarPillText.archived(name: outcome.name, hiddenOpenTasks: outcome.hiddenOpenTasks))
    }

    /// Delete from an area's menu: its projects stay, without an area. One undo step.
    static func deleteArea(_ area: KArea, model: AppModel) {
        guard let outcome = SidebarStoreActions.deleteArea(area.id, store: model.store) else { return }
        if model.scope == .area(area.id) {
            model.scope = .today
            model.persist()
        }
        model.didMutate()
        UndoToastCenter.shared.show(SidebarPillText.areaDeleted(name: outcome.name))
    }
}

extension SidebarScreen {
    func archiveProject(_ project: KProject) { SidebarMenuActions.archiveProject(project, model: model) }

    func deleteArea(_ area: KArea) { SidebarMenuActions.deleteArea(area, model: model) }

    /// The quiet shortcut text at the right edge of a footer row (rail mode shows none). Not read
    /// out by VoiceOver on its own: the row's tooltip carries the same information as words.
    @ViewBuilder
    func shortcutHint(forEntry id: String) -> some View {
        if !model.sidebarIconsOnly, let text = HotkeyRegistry.current(for: id).flatMap({ SidebarShortcutHint.text(caps: $0.displayKeys) }) {
            Text(verbatim: text)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .padding(.trailing, Metrics.sidebarRowTrailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The tooltip of a full-width row; the rail already shows the row's title as its tooltip.
    func rowTooltip(_ text: String) -> String { model.sidebarIconsOnly ? "" : text }
}
