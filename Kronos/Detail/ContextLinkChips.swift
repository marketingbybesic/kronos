// Kronos/Detail/ContextLinkChips.swift — attachment chips.
// A task AND each subtask carry any number of `ContextLink`s (one `link://` line each in their
// notes). Every chip opens its own item and its own X removes only that item — the previous
// build's X stripped EVERY `link://` line of the task. The open/resolve logic is shared by the
// inspector's LINKS row and the small chips on subtask rows so the two can never disagree.
import SwiftUI
import AppKit
import KronosCore

enum ContextLinkActions {
    static func iconName(_ kind: ContextLink.Kind) -> String {
        switch kind {
        case .appleNote: "note.text"
        case .file: "link"
        case .folder: "folder"
        case .web: "globe"
        case .email: "mail"
        }
    }

    /// A chip that can no longer open (file moved/deleted, or the legacy empty-reference shape)
    /// says so instead of looking normal and doing nothing on tap.
    static func isUnopenable(_ link: ContextLink) -> Bool {
        switch link.kind {
        case .file, .folder: resolveFileURL(link) == nil
        case .web: link.reference.isEmpty || URL(string: link.reference) == nil
        case .appleNote: false
        case .email: messageURL(link) == nil
        }
    }

    static func label(_ link: ContextLink) -> String {
        isUnopenable(link) ? String(format: String(localized: "detail.links.missing"), link.displayName) : link.displayName
    }

    /// What "Copy link" puts on the clipboard: the address of a web/mail link, the current path
    /// of a file or folder, the note's id for an Apple note.
    static func copyText(_ link: ContextLink) -> String {
        switch link.kind {
        case .file, .folder: resolveFileURL(link)?.url.path ?? link.reference
        case .web, .email, .appleNote: link.reference
        }
    }

    static func isFileLike(_ link: ContextLink) -> Bool { link.kind == .file || link.kind == .folder }

    /// Show in Finder for a file or folder: selects it in its parent folder.
    @MainActor
    static func reveal(_ link: ContextLink) {
        guard let resolved = resolveFileURL(link) else { return }
        withSecurityScope(resolved) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    }

    /// File -> revealed and selected in Finder; folder -> opened in Finder; email -> Mail shows
    /// exactly that message; note -> Notes shows that note (or just comes forward).
    @MainActor
    static func open(_ link: ContextLink, model: AppModel) {
        switch link.kind {
        case .appleNote:
            Task {
                do { try await model.notes.open(noteID: link.reference) } catch { openNotesApp() }
            }
        case .web:
            guard let url = URL(string: link.reference), !link.reference.isEmpty else { return }
            NSWorkspace.shared.open(url)
        case .file:
            guard let resolved = resolveFileURL(link) else { return }
            withSecurityScope(resolved) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        case .folder:
            guard let resolved = resolveFileURL(link) else { return }
            withSecurityScope(resolved) { NSWorkspace.shared.open($0) }
        case .email:
            guard let url = messageURL(link) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func remove(_ link: ContextLink, from target: AttachmentTarget, model: AppModel) {
        switch target {
        case .task(let id):
            model.store.update(id) { $0.notes = ContextLink.removing(link, from: $0.notes) }
        case .subtask(let s):
            model.store.updateSubtaskNotes(s.id, notes: ContextLink.removing(link, from: s.notes))
        }
        model.didMutate()
    }

    /// Mail's `message:%3C…%3E` as given; a reference with raw `<>` is percent-encoded first.
    private static func messageURL(_ link: ContextLink) -> URL? {
        guard link.reference.lowercased().hasPrefix("message:") else { return nil }
        return URL(string: link.reference)
            ?? link.reference.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    /// A security-scoped URL handed to NSWorkspace without start/stopAccessing gets
    /// LaunchServices' paramErr (-50).
    static func withSecurityScope(_ resolved: (url: URL, isSecurityScoped: Bool), _ action: (URL) -> Void) {
        guard resolved.isSecurityScoped else { action(resolved.url); return }
        let started = resolved.url.startAccessingSecurityScopedResource()
        action(resolved.url)
        if started { resolved.url.stopAccessingSecurityScopedResource() }
    }

    /// Bookmark first (survives moves/renames), else a raw path from an older link; nil when
    /// neither points at something that exists right now.
    static func resolveFileURL(_ link: ContextLink) -> (url: URL, isSecurityScoped: Bool)? {
        if let data = Data(base64Encoded: link.reference), !data.isEmpty {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return (url, true)
            }
        }
        let url = URL(fileURLWithPath: link.reference)
        return FileManager.default.fileExists(atPath: url.path) ? (url, false) : nil
    }

    private static func openNotesApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One attachment: icon + name (tap opens) and its own X (removes only this one). `compact`
/// is the subtask-row size: name capped so the subtask title keeps the room.
struct ContextLinkChip: View {
    let link: ContextLink
    let target: AttachmentTarget
    let model: AppModel
    var compact = false
    @State private var isRenaming = false
    @State private var nameDraft = ""

    var body: some View {
        // The remove ✕ lives inside the chip's own border (one pill, two sibling buttons), so the
        // chip's frame is the whole target and nothing hangs outside it.
        KChip(ContextLinkActions.label(link), trailing: .clear,
              onTap: { ContextLinkActions.open(link, model: model) },
              onTrailingTap: { ContextLinkActions.remove(link, from: target, model: model) },
              trailingAnchorID: "inspector.contextlink.remove") {
            Icon(ContextLinkActions.iconName(link.kind), size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
        }
        .frame(maxWidth: compact ? 140 : nil, alignment: .leading)
        .help(link.displayName)
        .uiTestAnchor("inspector.contextlink.chip")
        .contextMenu {
            Button(String(localized: "detail.links.chip.open")) { ContextLinkActions.open(link, model: model) }
            if ContextLinkActions.isFileLike(link) {
                Button(String(localized: "detail.links.chip.reveal")) { ContextLinkActions.reveal(link) }
            }
            Button(String(localized: "detail.links.chip.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ContextLinkActions.copyText(link), forType: .string)
            }
            Button(String(localized: "detail.links.chip.rename")) {
                nameDraft = link.displayName
                isRenaming = true
            }
            Divider()
            Button(String(localized: "detail.links.chip.remove")) { ContextLinkActions.remove(link, from: target, model: model) }
        }
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            ChipRenameField(name: $nameDraft) {
                LinkEditing.rename(link, to: nameDraft, on: target, model: model)
                isRenaming = false
            }
        }
    }
}

/// The rename popover: one field, Return saves, Escape closes (an unchanged or blank name
/// writes nothing — `LinkEditing.rename` ignores it).
private struct ChipRenameField: View {
    @Binding var name: String
    let onSave: () -> Void

    var body: some View {
        KTextField(String(localized: "detail.links.chip.rename.placeholder"), text: $name, autofocus: true)
            .onSubmit(onSave)
            .frame(width: 240)
            .padding(Space.x3)
            .background(Tok.overlay)
    }
}

/// The small chips to the right of a subtask's title.
struct SubtaskAttachmentChips: View {
    let model: AppModel
    let subtask: KTask

    var body: some View {
        let links = ContextLink.findAll(in: subtask.notes)
        if !links.isEmpty {
            HStack(spacing: Space.x1) {
                ForEach(links, id: \.encodedLine) { link in
                    // A file or folder attached on another Mac is dimmed and names that Mac.
                    ForeignAwareChip(link: link, target: .subtask(subtask), model: model, compact: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
