// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Kronos/Sidebar/SidebarSnapshots.swift
// Extra named screens for Kronos/Shared/SnapshotHarness.swift. "sidebar.projecteditor"
// exposes the popover's CONTENT view directly (popovers cannot be captured while
// presented) with a sample project named "Acme" per the ledger.
//
// The harness builds every screen's registry before it picks ONE to
// render, so any seeding done here (outside `.onAppear`) runs for every screen, not just
// the one being shot — an eager `KArea`/`KProject` built while constructing this
// dictionary leaked "Acme" into the plain "sidebar" and "shell" screenshots too. Every
// sample object below is built lazily inside the returned view's own `.onAppear`.
import SwiftUI
import KronosCore

@MainActor
enum SidebarSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "sidebar.projecteditor": AnyView(ProjectEditorSnapshot(model: model)),
            "sidebar.folders": AnyView(FoldersSnapshot(model: model)),
            "sidebar.views": AnyView(ViewsSnapshot(model: model)),
            "sidebar.archived": AnyView(ArchivedSnapshot(model: model)),
        ]
    }

    /// The project editor popover's content, seeded with one sample area + project so its
    /// area picker has something to show. Grew to 380x720 (ledger) once the Context folders
    /// section (feature M / SidebarProjectFolders.swift) landed below the area picker.
    private struct ProjectEditorSnapshot: View {
        let model: AppModel
        @State private var area: KArea?
        @State private var project: KProject?

        var body: some View {
            Group {
                if let area, let project {
                    SidebarProjectEditor(model: model, mode: .rename(project), areas: [area]) {}
                } else {
                    Tok.bg
                }
            }
            .onAppear {
                guard area == nil else { return }
                let a = KArea(name: "Globex", colorHex: KProjectPalette.swatches[6].color.hexString)
                area = a
                project = KProject(name: "Acme", colorHex: KProjectPalette.swatches[10].color.hexString,
                                    icon: "rocket", area: a)
            }
        }
    }

    /// The Context folders section alone (ledger G3/G9), fixture data only: one linked Apple
    /// Notes folder and one linked Finder folder, neutral names (Acme the project; Globex the
    /// Finder folder's display path) — never real client/person names, per stage-b-common.md.
    private struct FoldersSnapshot: View {
        let model: AppModel
        @State private var project: KProject?

        var body: some View {
            Group {
                if let project {
                    VStack(alignment: .leading, spacing: 0) {
                        SidebarProjectFolders(model: model, project: project)
                        Spacer(minLength: 0)
                    }
                    .padding(Space.x4)
                    .frame(width: Metrics.inspectorMin, alignment: .topLeading)
                    .background(Tok.overlay)
                } else {
                    Tok.bg
                }
            }
            .onAppear {
                guard project == nil else { return }
                let p = KProject(name: "Acme", colorHex: KProjectPalette.swatches[10].color.hexString,
                                  icon: "rocket", area: nil)
                project = p
                model.coach.update {
                    $0.projectFolders[p.id] = [
                        .appleNotes(folderName: "Acme"),
                        .finder(bookmark: Data(), displayPath: "~/Documents/Globex"),
                    ]
                }
            }
        }
    }

    /// Two saved views present, so the Saved Views section renders real rows.
    private struct ViewsSnapshot: View {
        let model: AppModel
        @State private var seeded = false

        var body: some View {
            SidebarScreen(model: model, scrollToBottomForSnapshot: true)
                .onAppear {
                    guard !seeded else { return }
                    seeded = true
                    // Real filters, so the row counts prove the count path (both read 37 with .empty).
                    var waiting = KFilter(); waiting.statuses = [KStatus.waiting.rawValue]
                    var high = KFilter(); high.priorities = [KPriority.high.rawValue, KPriority.urgent.rawValue]
                    model.store.createSavedView(name: "Waiting on others",
                                                 filter: waiting, sort: KSortDescriptor.default,
                                                 showDone: false)
                    model.store.createSavedView(name: "High priority",
                                                 filter: high, sort: KSortDescriptor.default,
                                                 showDone: false)
                    model.didMutate()
                }
        }
    }

    /// One archived project, with the Archived disclosure expanded.
    private struct ArchivedSnapshot: View {
        let model: AppModel
        @State private var seeded = false

        var body: some View {
            SidebarScreen(model: model, archivedExpandedForSnapshot: true, scrollToBottomForSnapshot: true)
                .onAppear {
                    guard !seeded else { return }
                    seeded = true
                    let project = model.store.createProject(name: "Old Website",
                                                             colorHex: KProjectPalette.swatches[3].color.hexString,
                                                             icon: nil, area: nil)
                    model.store.archiveProject(project.id)
                    model.didMutate()
                }
        }
    }
}
#endif
