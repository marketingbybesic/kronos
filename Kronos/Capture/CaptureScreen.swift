// Kronos/Capture/CaptureScreen.swift — UIContract's Capture seam.
//
// Paste or type notes, get proposed tasks as an editable checklist BEFORE anything is
// created, create the ticked ones in ONE undo step. Works with AI off (model.ai == nil):
// every state is built from the deterministic `NoteSplitter` pass and only quietly upgrades
// in place when a router is present. Frozen seam: `CaptureScreen(model:)`, closes by setting
// `model.isCaptureOpen = false`.
//
// `model.pendingCaptureText`: menu-bar meeting capture, the Siri CaptureNotes intent and
// project folders all hand text over this way. Read ONCE on appear, cleared immediately, and
// — since the caller already chose what to capture by sending the text — goes straight to
// "Find tasks" rather than sitting on the empty paste step.
import SwiftUI
import AppKit
import KronosCore

struct CaptureScreen: View {
    /// Snapshot-only entry points, applied once in `.onAppear` (Kronos/Capture/CaptureSnapshots.swift):
    /// drives the screen straight to a later step without the harness simulating typing or clicks.
    enum PreloadedStep { case pasted, review, done }

    let model: AppModel
    @State private var capture: CaptureModel
    private let preloadedText: String
    private let preloadedStep: PreloadedStep?

    init(model: AppModel) {
        self.model = model
        self._capture = State(initialValue: CaptureModel(model: model))
        self.preloadedText = ""
        self.preloadedStep = nil
    }

    /// Snapshot-only initializer; the frozen `init(model:)` above is what the shell calls.
    init(model: AppModel, preloadedText: String, preloadedStep: PreloadedStep) {
        self.model = model
        self._capture = State(initialValue: CaptureModel(model: model))
        self.preloadedText = preloadedText
        self.preloadedStep = preloadedStep
    }

    var body: some View {
        ZStack {
            Tok.bg
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.escape) { handleEscape(); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            handlePrimaryAction()
            return .handled
        }
        .onAppear { applyPreload(); consumePendingCaptureText() }
        .onReceive(NotificationCenter.default.publisher(for: .kronosCaptureFromFolderRequested)) { note in
            handleFolderRequest(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kronosPullFromNotesRequested)) { _ in
            Task { await pullFromNotesInbox() }
        }
    }

    private func applyPreload() {
        guard let preloadedStep else { return }
        capture.noteText = preloadedText
        switch preloadedStep {
        case .pasted: break
        case .review: capture.findTasks()
        case .done: capture.findTasks(); capture.create()
        }
    }

    /// The REAL path's own preload: text sent from outside the window (menu-bar meeting
    /// capture, Siri, a project folder) goes straight to Find Tasks — that text was already
    /// chosen for capture, so this is not a second empty paste step to click through.
    /// Read-once: `pendingCaptureText` is cleared immediately after reading it, matching the
    /// property's own "Capture reads it ONCE... and clears it" contract.
    private func consumePendingCaptureText() {
        guard preloadedStep == nil, let text = model.pendingCaptureText else { return }
        model.pendingCaptureText = nil
        capture.noteText = text
        capture.findTasks()
    }

    /// `kronosCaptureFromFolderRequested` (Sidebar project folders, "Add tasks from this
    /// folder"): the project preselects as default project (already true here, since the
    /// scope this closure runs in is the project the folder belongs to — set for safety in
    /// case Capture was opened from elsewhere), and the linked folder's own content becomes
    /// the source — an Apple Notes folder opens the picker already inside it (multi-select,
    /// same as "From Apple Notes"); a Finder folder reads its text-like files straight into
    /// the paste field. Both go through the SAME review step as any other source — a folder
    /// link never auto-creates a task directly.
    private func handleFolderRequest(_ note: Notification) {
        guard let projectID = note.userInfo?["projectID"] as? UUID,
              let linkID = note.userInfo?["linkID"] as? UUID else { return }
        if case .project = model.scope {} else { model.scope = .project(projectID) }
        guard let link = model.coach.settings.projectFolders[projectID]?.first(where: { $0.id == linkID }) else { return }
        switch link.kind {
        case .appleNotesFolder:
            guard let name = link.notesFolderName else { return }
            capture.notesSourceFolder = NoteFolderInfo(id: name, name: name)
        case .finderFolder:
            Task { await appendFinderFolderText(link) }
        }
    }

    /// Reads every `.md`/`.txt`/`.rtf` file directly inside a bookmarked Finder folder (not
    /// recursive — a flat "drop notes here" folder), size-capped the same way a single note's
    /// body already is implicitly by `PrivacyRedactor.sanitizeCapture`, and appends their text
    /// to the paste field. The bookmark is resolved security-scoped and released as soon as
    /// reading finishes.
    private func appendFinderFolderText(_ link: ProjectFolderLink) async {
        guard let data = link.folderBookmark else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let allowedExtensions: Set<String> = ["md", "txt", "rtf"]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        var bodies: [String] = []
        for fileURL in items where allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
            guard let text = readText(from: fileURL) else { continue }
            bodies.append(PrivacyRedactor.sanitizeCapture(text))
        }
        guard !bodies.isEmpty else { return }
        let joined = bodies.joined(separator: "\n\n")
        capture.noteText = capture.noteText.isEmpty ? joined : capture.noteText + "\n\n" + joined
    }

    /// `.rtf` needs `NSAttributedString`'s own reader; `.md`/`.txt` are plain UTF-8. A 200 KB
    /// cap per file keeps one oversized export from flooding the paste field — the same order
    /// of magnitude as `PrivacyRedactor.sanitizeCapture`'s own 6000-character prompt budget.
    private func readText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 200_000 else { return nil }
        if url.pathExtension.lowercased() == "rtf" {
            return (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                            documentAttributes: nil))?.string
        }
        return String(data: data, encoding: .utf8)
    }

    /// `kronosPullFromNotesRequested`: the Notes inbox folder, one tap, no picker — identical
    /// behaviour to CapturePasteView's own "Pull from Notes inbox" button.
    private func pullFromNotesInbox() async {
        let folder = model.coach.settings.notesInboxFolder
        guard let notes = try? await model.notes.notes(inFolder: folder) else { return }
        var bodies: [String] = []
        for note in notes {
            if let body = try? await model.notes.body(ofNoteID: note.id), !body.isEmpty { bodies.append(body) }
        }
        guard !bodies.isEmpty else { return }
        let joined = bodies.joined(separator: "\n\n")
        capture.noteText = capture.noteText.isEmpty ? joined : capture.noteText + "\n\n" + joined
    }

    @ViewBuilder
    private var content: some View {
        switch capture.step {
        case .paste:
            CapturePasteView(capture: capture, model: model)
        case .review:
            CaptureReviewList(capture: capture)
        case .done:
            CaptureDoneView(model: model, count: capture.createdCount, onFinished: capture.close)
        }
    }

    private func handleEscape() {
        switch capture.step {
        case .paste: model.isCaptureOpen = false
        case .review: capture.backToPaste()
        case .done: capture.close()
        }
    }

    private func handlePrimaryAction() {
        switch capture.step {
        case .paste: capture.findTasks()
        case .review: capture.create()
        case .done: capture.close()
        }
    }
}
