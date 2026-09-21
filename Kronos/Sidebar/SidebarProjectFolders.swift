// Kronos/Sidebar/SidebarProjectFolders.swift
// For workflows built around a project's own folder, where tasks usually get added from
// there: the "Context folders" section shown in the project editor
// (SidebarProjectEditor.swift) — linked folders as quiet rows (kind icon, display name,
// remove), "Link Finder folder..." (NSOpenPanel, directories only), "Link Notes folder..."
// (a picker over `model.notes.folders()`, calm allow row when access is missing), and ONE
// obvious action per folder: "Add tasks from this folder".
//
// Storage: `CoachSettings.projectFolders[project.id]` (Core) via `model.coach.update { }` —
// folder links are coach/context data, not a task-store field, so removing one is a plain
// settings write with nothing to undo (removal asks nothing and can be re-added).
//
// "Add tasks from this folder" hands off to Capture rather than reading the folder itself:
// this posts `kronosCaptureFromFolderRequested` with the project and link ids and opens
// Capture; CaptureScreen observes it and pre-fills that folder's notes.
import AppKit
import SwiftUI
import KronosCore

/// UI presentation split of `ProjectFolderLink.displayPath`: the row name is the folder's own
/// name, the path/kind is a separate, quieter second line — never added to Core since
/// `ProjectFolderLink` is plain data and this wording is UI-only.
private extension ProjectFolderLink {
    /// The folder's own name: the last path component for a Finder link (`displayPath` is
    /// the full path), or the folder name itself for a Notes link (`displayPath` already IS
    /// just the name — `.appleNotes(folderName:)` sets both to the same string).
    var name: String {
        switch kind {
        case .appleNotesFolder: return notesFolderName ?? displayPath
        case .finderFolder: return (displayPath as NSString).lastPathComponent
        }
    }

    /// Second line: the parent directory for a Finder link (nothing repeats the name line),
    /// or "Apple Notes" for a Notes link, which has no path to show.
    var subtitle: String {
        switch kind {
        case .appleNotesFolder: return String(localized: "sidebar.projecteditor.folders.applenotes")
        case .finderFolder: return (displayPath as NSString).deletingLastPathComponent
        }
    }
}

extension Notification.Name {
    /// Posted when "Add tasks from this folder" is picked. userInfo:
    /// `["projectID": UUID, "linkID": UUID]`. CaptureScreen observes this, prefills the
    /// folder's source, and relies on `AppModel.isCaptureOpen` (already set true here) to
    /// present it.
    static let kronosCaptureFromFolderRequested = Notification.Name("kronosCaptureFromFolderRequested")
}

/// The context-folders section body: a quiet row per linked folder plus the two "Link…"
/// actions. Used inline by `SidebarProjectEditor`; kept in its own file/type so the editor
/// stays readable and this piece is independently snapshot-able (`sidebar.folders`).
struct SidebarProjectFolders: View {
    let model: AppModel
    let project: KProject

    @State private var notesPickerOpen = false

    private var links: [ProjectFolderLink] { model.coach.settings.projectFolders[project.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: "sidebar.projecteditor.folders"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)

            if links.isEmpty {
                Text(String(localized: "sidebar.projecteditor.folders.empty"))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(links) { link in
                        folderRow(link)
                    }
                }
            }

            // Driver review (19.09): a boxed `.secondary` button pair on one line truncated
            // in both languages ("Poveži mapu iz Findera…" alone is wider than half the
            // popover). Quiet leading-plus text rows instead, stacked and leading-aligned,
            // matching the sidebar's own add-row idiom — a label this long only has to fit
            // ONE column, not share a line with a sibling.
            VStack(alignment: .leading, spacing: Space.x1) {
                addRow(String(localized: "sidebar.projecteditor.folders.linkfinder"), action: linkFinderFolder)
                addRow(String(localized: "sidebar.projecteditor.folders.linknotes")) { notesPickerOpen = true }
            }
        }
        .popover(isPresented: $notesPickerOpen) {
            SidebarNotesFolderPicker(model: model) { name in
                addLink(.appleNotes(folderName: name))
                notesPickerOpen = false
            }
        }
    }

    private func addRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.x1) {
                Icon("plus", size: Metrics.iconS)
                Text(title)
            }
        }
        .kButton(.ghost, size: .compact)
        .fixedSize()
    }

    // MARK: One linked folder

    /// Two lines: line 1 is the kind icon + folder NAME only (tail truncation allowed here —
    /// a name can legitimately be long) with "Add tasks" and the
    /// remove x sharing one trailing edge; line 2 is the parent path (Finder) or "Apple
    /// Notes" (a note folder has no path) at the tertiary tone, never truncated since it is
    /// short by construction on any real folder.
    private func folderRow(_ link: ProjectFolderLink) -> some View {
        VStack(alignment: .leading, spacing: Space.x1 / 2) {
            HStack(spacing: Space.x2) {
                Icon(link.kind == .appleNotesFolder ? "book-open" : "folder", size: Metrics.iconM)
                    .foregroundStyle(Tok.textTertiary)
                Text(link.name)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.x2)
                // The one obvious action per folder: a plain button, not buried in a menu,
                // since it is the whole point of linking a folder in the first place.
                // `.fixedSize()` — a button label never truncates.
                Button(String(localized: "sidebar.projecteditor.folders.addtasks")) {
                    addTasks(from: link)
                }
                .kButton(.ghost, size: .compact)
                .fixedSize()
                Button {
                    removeLink(link)
                } label: {
                    Icon("x", size: Metrics.iconS)
                }
                .kButton(.icon)
                .accessibilityLabel(String(localized: "sidebar.projecteditor.folders.remove"))
            }
            Text(link.subtitle)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
                .padding(.leading, Metrics.iconM + Space.x2)
        }
        .padding(.vertical, Space.x1)
    }

    // MARK: Actions

    private func linkFinderFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let link = SidebarFolderDropClassifier.link(for: url) else { return }
        addLink(link)
    }

    private func addLink(_ link: ProjectFolderLink) {
        model.coach.update { $0.projectFolders[project.id, default: []].append(link) }
    }

    private func removeLink(_ link: ProjectFolderLink) {
        model.coach.update { $0.projectFolders[project.id]?.removeAll { $0.id == link.id } }
    }

    private func addTasks(from link: ProjectFolderLink) {
        NotificationCenter.default.post(name: .kronosCaptureFromFolderRequested, object: nil,
                                         userInfo: ["projectID": project.id, "linkID": link.id])
        model.isCaptureOpen = true
    }
}

/// A Notes folder picker over `model.notes.folders()`. Missing/denied Automation access
/// (`.notAuthorised` and `.timedOut` alike, per the coach brief) shows a calm "Allow access"
/// row that opens System Settings' Automation pane — never a crash, never a retry loop.
private struct SidebarNotesFolderPicker: View {
    let model: AppModel
    let onPick: (String) -> Void

    private enum State {
        case loading, needsAccess, loaded([NoteFolderInfo])
    }
    @State private var state: State = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: "sidebar.projecteditor.folders.linknotes.title"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)

            switch state {
            case .loading:
                Text(String(localized: "sidebar.projecteditor.folders.linknotes.loading"))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textTertiary)
            case .needsAccess:
                allowAccessRow
            case .loaded(let folders):
                if folders.isEmpty {
                    Text(String(localized: "sidebar.projecteditor.folders.linknotes.empty"))
                        .font(Typo.row)
                        .foregroundStyle(Tok.textTertiary)
                } else {
                    ForEach(folders) { folder in
                        Button(folder.name) { onPick(folder.name) }
                            .kButton(.ghost)
                    }
                }
            }
        }
        .padding(Space.x4)
        .frame(width: Metrics.inspectorMin)
        .background(Tok.overlay)
        .task { await load() }
    }

    /// Calm, specific, one action — no exclamation, no shame (coach copy rules apply even
    /// to a plain permissions row, since nobody may be present when this is first seen).
    private var allowAccessRow: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: "sidebar.projecteditor.folders.linknotes.noaccess"))
                .font(Typo.row)
                .foregroundStyle(Tok.textSecondary)
            Button(String(localized: "sidebar.projecteditor.folders.linknotes.opensettings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .kButton(.secondary, size: .compact)
        }
    }

    private func load() async {
        // Every failure (not just `.notAuthorised`/`.timedOut`) degrades to the same calm
        // row — there is no case where crashing or retrying is the right answer here.
        do {
            state = .loaded(try await model.notes.folders())
        } catch {
            state = .needsAccess
        }
    }
}
