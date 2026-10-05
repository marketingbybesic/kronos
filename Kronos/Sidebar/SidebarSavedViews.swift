// Kronos/Sidebar/SidebarSavedViews.swift
// The slim "Views" section: only the views that belong to no project on the sidebar (saved before views
// were per project, or saved from a list that is not a project). A view of a project is a child row under
// that project (SidebarSavedViewRows.swift), so this section is not drawn at all while it would be empty.
// Views are created from the list's "Save as view"; this section only selects, renames and deletes.
import SwiftUI
import KronosCore

struct SidebarSavedViewsSection: View {
    let model: AppModel

    var body: some View {
        // Reading `model.version` makes @Observable re-evaluate `views` on mutation. Saved views carry no
        // number: only Inbox and Today do (SidebarScreen.showsCount).
        let _ = model.version
        let views = Self.globalViews(in: model.store)
        Group {
            if !views.isEmpty {
                KSectionHeader(String(localized: "sidebar.section.views"))
                    .uiTestAnchor("sidebar.views.header")
                ForEach(views) { view in
                    SidebarSavedViewRow(model: model, view: view, indent: 0, count: nil)
                }
            }
        }
    }

    /// The views that have no project row to sit under: no single pinned project, or one that is archived
    /// or gone (the view stays reachable here).
    static func globalViews(in store: TaskStore) -> [KSavedView] {
        let shown = Set(store.allProjects().map(\.id))
        return store.allSavedViews().filter { view in
            guard let home = view.homeProjectID else { return true }
            return !shown.contains(home)
        }
    }
}
