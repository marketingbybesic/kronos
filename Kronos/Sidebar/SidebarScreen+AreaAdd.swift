// Kronos/Sidebar/SidebarScreen+AreaAdd.swift
// Pure move, no behaviour change, out of SidebarScreen.swift to keep that file under the
// 500-line gate — the Area row's hover "+" button is a self-contained unit (only
// reads/writes `hoveredAreaID`, `editorTarget`), same pattern as TaskListScreen+Parts.swift.
// A "+" appears on mouse hover for adding a project inside an Area.
import SwiftUI
import KronosCore

extension SidebarScreen {
    func areaAddProjectButton(_ area: KArea, index: Int, visible: Bool) -> some View {
        Button {
            editorTarget = EditorTarget(mode: .create(area: area))
        } label: {
            Icon("plus", size: Metrics.iconS)
                .foregroundStyle(Tok.textTertiary)
                .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, Metrics.sidebarRowTrailing)
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(false)
        .accessibilityLabel(String(format: String(localized: "sidebar.area.add.project"), area.name))
        .uiTestAnchor("sidebar.area.add.\(index)")
    }

    /// Context-menu mirror of the editor's "Context folders" section (ledger G9: the project
    /// context menu AND the editor both list linked folders) — same store, same actions,
    /// just reachable without opening the popover.
    @ViewBuilder
    func projectFolderMenuItems(_ project: KProject) -> some View {
        let links = model.coach.settings.projectFolders[project.id] ?? []
        ForEach(links) { link in
            Menu(link.displayPath) {
                Button(String(localized: "sidebar.projecteditor.folders.addtasks")) {
                    NotificationCenter.default.post(name: .kronosCaptureFromFolderRequested, object: nil,
                                                     userInfo: ["projectID": project.id, "linkID": link.id])
                    model.isCaptureOpen = true
                }
                Button(String(localized: "sidebar.projecteditor.folders.remove")) {
                    model.coach.update { $0.projectFolders[project.id]?.removeAll { $0.id == link.id } }
                }
            }
        }
        Button(String(localized: "ctx.project.folders")) {
            editorTarget = EditorTarget(mode: .rename(project))
        }
    }

    func hasLinkedFolders(_ project: KProject) -> Bool {
        !(model.coach.settings.projectFolders[project.id] ?? []).isEmpty
    }
}
