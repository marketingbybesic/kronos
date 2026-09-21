// Kronos/Capture/NotesPickerSheet.swift — folder -> note picker over `model.notes`
// (AppleNotesBridge). Shared by the inspector's "Link Apple note" (single select,
// Kronos/Detail/InspectorCoachSection.swift) and Capture's "From Apple Notes" source
// (multi-select, CapturePasteView.swift) — one component, since both are the same two-level
// list with the same missing-access state, differing only in whether tapping a note finishes
// the sheet immediately or just toggles a checkmark.
//
// Missing/denied Automation access (`.notAuthorised` or `.timedOut` both read as the same calm
// state) shows one "Allow access in System Settings" row and NEVER retries automatically or
// nags; a fresh attempt is triggered by reopening the sheet.
//
// Drag-and-drop for assigning a note was reported dead; the picker itself was never the
// problem, the entry point was, so this sheet gained search (type to filter by title, focused
// open), most-recently-modified-first sort (was insertion order), and full keyboard nav
// (arrows + Return + Esc) — the same filter-as-you-type + arrow-key idiom CommandPaletteView
// already uses (KeyCatcher: a local NSEvent monitor, since SwiftUI's `.onKeyPress` does not
// fire while a TextField holds first responder).
import SwiftUI
import AppKit
import KronosCore

struct NotesPickerSheet: View {
    enum Mode {
        /// Detail's note-link picker: tapping a note links it and closes the sheet.
        case single(onPick: (NoteInfo, String) -> Void)
        /// Capture's "From Apple Notes" source: notes toggle a checkmark; "Add" hands back
        /// every selected note's plain-text body, joined, to the caller.
        case multi(onAdd: ([NoteInfo]) -> Void)
    }

    let model: AppModel
    var mode: Mode = .single(onPick: { _, _ in })
    /// Opens straight into this folder, skipping the folder list — used for real by "Add
    /// tasks from this folder" on a project's linked Notes folder (a project already knows
    /// which folder it means, so there is nothing to pick), and by `inspector.links`'s and
    /// `capture.notes`' fixtures to show the richer note-list state in one shot.
    var initialFolder: NoteFolderInfo? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [NoteFolderInfo] = []
    @State private var selectedFolder: NoteFolderInfo?
    @State private var notes: [NoteInfo] = []
    @State private var selectedNoteIDs: Set<String> = []
    @State private var loadError: NotesError?
    @State private var isLoading = false
    @State private var query = ""
    @State private var highlightedID: String?

    /// Folders whose name matches `query` (case/diacritic-insensitive substring) — folder list
    /// only, notes are filtered separately by `filteredNotes`.
    private var filteredFolders: [NoteFolderInfo] {
        guard !query.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Notes matching `query` by title, most-recently-modified first — the bridge returns
    /// folder order, this view owns the sort.
    private var filteredNotes: [NoteInfo] {
        let base = notes.sorted { $0.modifiedAt > $1.modifiedAt }
        guard !query.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// What the keyboard/rows below iterate: folders while none is picked, else that folder's
    /// notes. Search narrows whichever list is showing.
    private var rowIDs: [String] {
        selectedFolder != nil ? filteredNotes.map(\.id) : filteredFolders.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            KHairline()
            content
            KHairline()
            footer
        }
        .frame(width: 480, height: 560)
        .background(Tok.bg)
        .task {
            if let initialFolder { await selectFolder(initialFolder) }
            else { await loadFolders() }
        }
        .onChange(of: query) { _, _ in highlightedID = rowIDs.first }
        .onChange(of: selectedFolder) { _, _ in highlightedID = rowIDs.first }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "capture.notes.picker.title"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            Spacer()
            if let selectedFolder {
                Button(selectedFolder.name) { self.selectedFolder = nil; query = "" }
                    .buttonStyle(.plain)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
        .padding(Space.x4)
    }

    /// Opens focused in the search field, type-to-filter, arrows/Return/Esc caught here the
    /// same way CommandPaletteView's own field does — a local key monitor, since a TextField's
    /// first responder swallows SwiftUI's `.onKeyPress`.
    private var searchField: some View {
        KTextField(String(localized: "capture.notes.picker.search"), text: $query, leading: "search", autofocus: true)
            .padding(.horizontal, Space.x4)
            .padding(.bottom, Space.x2)
            .background(KeyCatcher(onKey: handleKey))
            .uiTestAnchor("notespicker.search")
    }

    @ViewBuilder
    private var content: some View {
        if loadError != nil {
            // A full KEmptyState (not the Inspector's compact NotesAccessDeniedInline row —
            // that one shares a single property-row line with the rest of the inspector and
            // would be oversized here) since this sheet has an entire pane to itself, same
            // presentation as the "no folders" / "no notes" states right below. The message
            // line says what granting access actually gives the user — real content, not
            // filler, for a screen that otherwise has nothing else to show.
            KEmptyState(icon: "info", title: String(localized: "capture.notes.denied.body"),
                       message: String(localized: "capture.notes.denied.message"),
                       actionTitle: String(localized: "capture.notes.denied.action"), onAction: openAutomationSettings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .uiTestAnchor("notespicker.denied")
        } else if isLoading {
            // Loading titles only, over osascript, can take real time for a large vault, and
            // must not block the main thread — this is the visible feedback while the already
            // async/awaited bridge calls run.
            VStack {
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .uiTestAnchor("notespicker.loading")
        } else if let selectedFolder {
            noteList(in: selectedFolder)
        } else if folders.isEmpty {
            KEmptyState(icon: "folder", title: String(localized: "capture.notes.picker.empty"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .uiTestAnchor("notespicker.empty")
        } else {
            folderList
        }
    }

    private var folderList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredFolders.isEmpty {
                    KEmptyState(icon: "folder", title: String(localized: "capture.notes.picker.empty"))
                        .padding(.top, Space.x5)
                        .uiTestAnchor("notespicker.empty")
                }
                ForEach(filteredFolders) { folder in
                    Button { Task { await selectFolder(folder) } } label: {
                        HStack(spacing: Space.x2) {
                            Icon("folder", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                            Text(folder.name).font(Typo.row).foregroundStyle(Tok.textPrimary)
                            Spacer()
                            Icon("chevron-right", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                        }
                        .frame(height: Metrics.controlRegular)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(highlightedID == folder.id ? Tok.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .uiTestAnchor("notespicker.folder." + folder.name)
                }
            }
            .padding(.horizontal, Space.x4)
            .padding(.vertical, Space.x2)
        }
    }

    private func noteList(in folder: NoteFolderInfo) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredNotes.isEmpty {
                    KEmptyState(icon: "mail", title: String(localized: "capture.notes.picker.empty"))
                        .padding(.top, Space.x5)
                        .uiTestAnchor("notespicker.empty")
                }
                ForEach(filteredNotes) { note in
                    noteRow(note, folder: folder)
                }
            }
            .padding(.horizontal, Space.x4)
            .padding(.vertical, Space.x2)
        }
    }

    /// Folder name as secondary text under the title — meaningful once search can surface a
    /// note found while browsing a specific folder, and consistent even though today's nav
    /// only ever lists one folder's notes at a time.
    private func noteRow(_ note: NoteInfo, folder: NoteFolderInfo) -> some View {
        // `.frame(height: Metrics.controlRegular)` (a single-line control height) squeezed this
        // row's TWO lines of text (title + folder secondary line) — the folder line of one row
        // touched the title of the next, no vertical breathing room. Vertical padding replaces
        // the fixed single-line height so the two-line content sizes itself; the tap target
        // (frame + contentShape) and the selected-row highlight both stay on the padded row,
        // same as every other control in this file.
        Button { Task { await pick(note) } } label: {
            HStack(spacing: Space.x2) {
                if case .multi = mode {
                    KCheckbox(isChecked: selectedNoteIDs.contains(note.id), size: Metrics.listCheckboxSize) {}
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(note.title).font(Typo.row).foregroundStyle(Tok.textPrimary).lineLimit(1)
                    Text(folder.name).font(Typo.meta).foregroundStyle(Tok.textTertiary).lineLimit(1)
                }
                Spacer()
                Text(Self.modifiedFormatter.localizedString(for: note.modifiedAt, relativeTo: Date()))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, Space.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(highlightedID == note.id ? Tok.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .uiTestAnchor("notespicker.row." + note.title)
    }

    @ViewBuilder
    private var footer: some View {
        if case .multi(let onAdd) = mode {
            HStack {
                Spacer()
                Button(String(format: String(localized: "capture.notes.picker.add_n"), selectedNoteIDs.count)) {
                    Task { await finishMulti(onAdd) }
                }
                .kButton(.primary)
                .disabled(selectedNoteIDs.isEmpty)
            }
            .padding(Space.x4)
        }
    }

    private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.specialKey {
        case .some(.upArrow): move(-1); return true
        case .some(.downArrow): move(1); return true
        default: break
        }
        if event.keyCode == 53 { // Esc: back out of a folder first, else close the sheet
            if selectedFolder != nil { selectedFolder = nil; query = ""; return true }
            dismiss(); return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Return
            activateHighlighted(); return true
        }
        return false
    }

    private func move(_ delta: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == highlightedID } ?? 0
        let next = ((current + delta) % ids.count + ids.count) % ids.count
        highlightedID = ids[next]
    }

    private func activateHighlighted() {
        guard let id = highlightedID else { return }
        if let folder = filteredFolders.first(where: { $0.id == id }), selectedFolder == nil {
            Task { await selectFolder(folder) }
        } else if let note = filteredNotes.first(where: { $0.id == id }) {
            Task { await pick(note) }
        }
    }

    // MARK: - Loading

    private func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await model.notes.folders()
            loadError = nil
        } catch let e as NotesError {
            loadError = e
        } catch {
            loadError = .unexpected("\(error)")
        }
        highlightedID = rowIDs.first
    }

    private func selectFolder(_ folder: NoteFolderInfo) async {
        selectedFolder = folder
        query = ""
        isLoading = true
        defer { isLoading = false }
        do {
            notes = try await model.notes.notes(inFolder: folder.name)
            loadError = nil
        } catch let e as NotesError {
            loadError = e
        } catch {
            loadError = .unexpected("\(error)")
        }
        highlightedID = rowIDs.first
    }

    private func pick(_ note: NoteInfo) async {
        switch mode {
        case .single(let onPick):
            guard let body = try? await model.notes.body(ofNoteID: note.id) else {
                onPick(note, "")
                dismiss()
                return
            }
            onPick(note, body)
            dismiss()
        case .multi:
            if selectedNoteIDs.contains(note.id) { selectedNoteIDs.remove(note.id) }
            else { selectedNoteIDs.insert(note.id) }
        }
    }

    private func finishMulti(_ onAdd: ([NoteInfo]) -> Void) async {
        let picked = notes.filter { selectedNoteIDs.contains($0.id) }
        onAdd(picked)
        dismiss()
    }

    private static let modifiedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateTimeStyle = .named
        return f
    }()
}

/// Installs a local NSEvent monitor scoped to this view's lifetime so arrow/Return/Esc reach the
/// picker even while the search field owns first responder — mirrors
/// Kronos/Palette/CommandPaletteView.swift's own `KeyCatcher` (SwiftUI's `.onKeyPress` does not
/// fire while a TextField holds the field editor). Kept as a private copy rather than sharing
/// that type: CommandPaletteView.swift is outside this file's ownership boundary.
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                onKey(event) ? nil : event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
