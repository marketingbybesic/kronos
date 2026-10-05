// Kronos/Sidebar/SidebarSavedViewRows.swift
// A saved view as a sidebar row, and the rows of the views that belong to one project, drawn as indented
// children under that project's row (they show and hide with it). A view belongs to a project when its
// filter pins exactly that one (KSavedView.homeProjectID): nothing is stored besides the filter.
import SwiftUI
import KronosCore

/// The views of one project (already picked by the screen, in the order the person keeps them), one step
/// deeper than the project row.
struct SidebarProjectViewRows: View {
    let model: AppModel
    let views: [KSavedView]
    let indent: Int
    /// Every task, fetched once per sidebar pass by the screen, for the numbers beside the rows.
    let tasks: [KTask]

    var body: some View {
        let today = Day.today()
        ForEach(views) { view in
            SidebarSavedViewRow(model: model, view: view, indent: indent,
                                count: view.memberCount(in: tasks, today: today))
        }
    }
}

/// One saved view: select, rename and delete from the context menu.
struct SidebarSavedViewRow: View {
    let model: AppModel
    let view: KSavedView
    let indent: Int
    let count: Int?

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        KSidebarRow(title: view.name,
                    leadingIcon: "bookmark",
                    count: count.flatMap { $0 == 0 ? nil : $0 },
                    indent: indent,
                    isSelected: model.scope == .savedView(view.id)) {
            select()
        }
        .uiTestAnchor("sidebar.view.\(view.id.uuidString)")
        .contextMenu {
            Button(String(localized: "common.rename")) {
                renameText = view.name
                isRenaming = true
            }
            Button(String(localized: "common.delete")) { delete() }
        }
        .popover(isPresented: $isRenaming) { renameEditor }
    }

    private var renameEditor: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(String(localized: "common.rename"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            KTextField(String(localized: "sidebar.projecteditor.name"), text: $renameText)
                .onSubmit(commitRename)
            HStack {
                Button(String(localized: "common.cancel")) { isRenaming = false }
                    .kButton(.secondary)
                Spacer()
                Button(String(localized: "common.save"), action: commitRename)
                    .kButton(.primary)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(Space.x4)
        .frame(width: Metrics.inspectorMin)
        .background(Tok.overlay)
    }

    private var trimmedName: String { renameText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commitRename() {
        guard !trimmedName.isEmpty else { return }
        model.store.updateSavedView(view.id, name: trimmedName, filter: nil, sort: nil, showDone: nil)
        model.didMutate()
        isRenaming = false
    }

    private func select() {
        let scope = ListScope.savedView(view.id)
        model.scope = scope
        // A view of a project always opens with its project: options kept from an earlier edit that lost
        // the pin are put back (a view with no such edits answers with its own filter, already pinned).
        if let pin = view.homeProjectID {
            let current = model.options(for: scope)
            let repaired = current.pinned(to: pin)
            if repaired != current { model.setOptions(repaired, for: scope) }
        }
        model.persist()
    }

    /// Deletes the view (one undo step, a pill). A list that was showing it goes back to its project,
    /// or to All Tasks for a view of its own.
    private func delete() {
        let name = view.name
        let wasOpen = model.scope == .savedView(view.id)
        let home = view.homeProjectID
        model.store.deleteSavedView(view.id)
        if wasOpen {
            model.scope = home.map { ListScope.project($0) } ?? .all
            model.persist()
        }
        model.commit(String(format: String(localized: "list.pill.viewdeleted"), name))
    }
}
