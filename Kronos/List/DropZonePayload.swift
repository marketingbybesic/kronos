// Kronos/List/DropZonePayload.swift
// Reads what is being dragged off a drag pasteboard: Kronos's own task and step rows, Mail
// messages, Finder files and folders, Apple Notes notes, web URLs, plain text. Synchronous and
// read-only, so it works inside the drag callbacks before the session can be torn down, and the
// live UI test feeds it a real NSPasteboard of its own.
//
// Hard rule: a link is never stored empty. An item whose reference cannot be read becomes a task
// with a title and no chip, never a chip that cannot open.
import AppKit
import UniformTypeIdentifiers
import KronosCore

/// One external item that becomes a new task or a link on an existing row.
struct ExternalDropItem: Equatable {
    /// The new task's title. Always non-empty.
    var title: String
    /// The link chip; nil when the source gave no usable reference yet (see `needsNoteLookup`).
    var link: ContextLink?
    /// Mail only: the message URL when the pasteboard carried no subject and it is still to be
    /// read from Mail's Envelope Index (title is a placeholder until then).
    var mailURLNeedingSubject: String?
    /// Notes only: the note title to resolve to a note id through the Notes bridge.
    var noteTitleToResolve: String?

    var needsResolution: Bool { mailURLNeedingSubject != nil || noteTitleToResolve != nil }
}

enum DropPayload: Equatable {
    case task(UUID)
    case subtask(UUID)
    case external([ExternalDropItem])
    case unsupported

    /// The resolver's view of the payload; nil when nothing can be dropped.
    @MainActor func subject(model: AppModel) -> DropSubject? {
        switch self {
        case .task(let id):
            return model.store.task(id) == nil ? nil : .task(id)
        case .subtask(let id):
            guard let parent = model.store.subtaskOwnerID(id) else { return nil }
            return .subtask(id, parent: parent)
        case .external(let items):
            return items.isEmpty ? nil : .external
        case .unsupported:
            return nil
        }
    }
}

enum DropZonePayloadReader {
    static let taskPrefix = "kronos-task:"
    static let subtaskPrefix = MailDropPasteboard.subtaskDragPrefix   // "kronos-subtask:"

    /// Notes registers its drags under private identifiers; any of these marks a Notes drag.
    static let notesTypeNames: Set<String> = [
        "com.apple.notes.note", "com.apple.notes.richtext", "com.apple.notes", "com.apple.notes.noteitem",
    ]

    /// The private type a task row's drag carries its own `kronos-task:<uuid>` marker under. Plain
    /// text is free for what a terminal or an agent should read; the marker lives here, first.
    static let dragItemTypeID = "app.kronos.drag-item"
    static let dragItemType = NSPasteboard.PasteboardType(dragItemTypeID)

    /// The task id of a Kronos task-row drag: the private type first, then the legacy plain-text
    /// marker (older clipboards, Services, scripted pasteboards).
    static func draggedTaskID(from pasteboard: NSPasteboard) -> UUID? {
        if let data = pasteboard.data(forType: dragItemType), let text = String(data: data, encoding: .utf8),
           text.hasPrefix(taskPrefix), let id = UUID(uuidString: String(text.dropFirst(taskPrefix.count))) { return id }
        if let text = pasteboard.string(forType: .string),
           text.hasPrefix(taskPrefix), let id = UUID(uuidString: String(text.dropFirst(taskPrefix.count))) { return id }
        return nil
    }

    static func read(_ pasteboard: NSPasteboard) -> DropPayload {
        if let id = draggedTaskID(from: pasteboard) { return .task(id) }
        if let data = pasteboard.data(forType: dragItemType), let text = String(data: data, encoding: .utf8),
           text.hasPrefix(subtaskPrefix), let id = UUID(uuidString: String(text.dropFirst(subtaskPrefix.count))) { return .subtask(id) }
        if let text = pasteboard.string(forType: .string),
           text.hasPrefix(subtaskPrefix), let id = UUID(uuidString: String(text.dropFirst(subtaskPrefix.count))) { return .subtask(id) }

        // Mail: one `message:` URL per message.
        let mail = MailDropPasteboard.messages(from: pasteboard)
        if !mail.isEmpty {
            let items: [ExternalDropItem] = mail.compactMap { m in
                let url = m.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                let name = m.subject ?? ""
                return ExternalDropItem(
                    title: name.isEmpty ? String(localized: "detail.links.email.untitled") : name,
                    link: ContextLink(kind: .email, reference: url,
                                      displayName: name.isEmpty ? String(localized: "detail.links.email.untitled") : name),
                    mailURLNeedingSubject: name.isEmpty ? url : nil,
                    noteTitleToResolve: nil)
            }
            if !items.isEmpty { return .external(items) }
        }

        // Finder: real file URLs.
        let files = FileDropPasteboard.fileURLs(from: pasteboard)
        if !files.isEmpty {
            let items: [ExternalDropItem] = files.compactMap { url in
                let fields = FileDropPasteboard.fields(for: url)
                guard !fields.reference.isEmpty else { return nil }
                return ExternalDropItem(title: fileTitle(for: url, isDirectory: fields.isDirectory),
                                        link: fields.contextLink, mailURLNeedingSubject: nil, noteTitleToResolve: nil)
            }
            if !items.isEmpty { return .external(items) }
        }

        let typeNames = Set((pasteboard.types ?? []).map(\.rawValue))
            .union((pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })

        // Notes: the drag carries the note's text; its id is looked up by title afterwards.
        if !typeNames.isDisjoint(with: notesTypeNames) {
            let urlText = pasteboard.string(forType: .URL)
            if let urlText, let id = noteID(fromURLString: urlText) {
                let title = firstLine(of: pasteboard.string(forType: .string)) ?? id
                return .external([ExternalDropItem(title: title, link: ContextLink(kind: .appleNote, reference: id, displayName: title),
                                                   mailURLNeedingSubject: nil, noteTitleToResolve: nil)])
            }
            if let title = firstLine(of: pasteboard.string(forType: .string)) {
                return .external([ExternalDropItem(title: title, link: nil, mailURLNeedingSubject: nil, noteTitleToResolve: title)])
            }
            return .unsupported
        }

        // A web URL (browser tab, link).
        if let urlText = pasteboard.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let title = url.host.map { $0 + (url.path == "/" ? "" : url.path) } ?? urlText
            return .external([ExternalDropItem(title: title, link: ContextLink(kind: .web, reference: urlText, displayName: title),
                                               mailURLNeedingSubject: nil, noteTitleToResolve: nil)])
        }

        // Plain text: a task titled by its first line, no link.
        if let title = firstLine(of: pasteboard.string(forType: .string)) {
            return .external([ExternalDropItem(title: title, link: nil, mailURLNeedingSubject: nil, noteTitleToResolve: nil)])
        }
        return .unsupported
    }

    /// File name without extension; a folder keeps its whole name (a dot in it is not an extension).
    static func fileTitle(for url: URL, isDirectory: Bool) -> String {
        let name = url.lastPathComponent
        let base = isDirectory ? name : url.deletingPathExtension().lastPathComponent
        let title = base.isEmpty ? name : base
        return title.isEmpty ? url.path : title
    }

    static func firstLine(of text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : line
    }

    private static func noteID(fromURLString s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["notes://", "applenotes:"] where t.hasPrefix(prefix) {
            let id = String(t.dropFirst(prefix.count))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    /// Drag-source side: the pasteboard strings Kronos rows put on a drag.
    static func taskDragString(_ id: UUID) -> String { taskPrefix + id.uuidString }
    static func subtaskDragString(_ id: UUID) -> String { subtaskPrefix + id.uuidString }
}

@MainActor
extension TaskStore {
    /// The task a step belongs to (a drag only knows the step id); nil for a top-level or missing row.
    func subtaskOwnerID(_ id: UUID) -> UUID? {
        task(id)?.parentID
    }
}

// MARK: - Drag out

/// What a row puts on the drag pasteboard. A task row registers its own marker (`kronos-task:<uuid>`)
/// FIRST under the private `app.kronos.drag-item` type, so Kronos's drop targets (moves, nesting,
/// the attach guards) read it from there. Plain text, the one thing a terminal or an agent prompt
/// reads, then carries the task as a readable dossier (`TaskDragText`) ending in its Kronos link.
/// Behind them come the title as rich text with the link on it and the `kronos://open?id=` URL, for
/// TextEdit, Notes, Mail and anything else a row is dragged into. A subtask row (and a task asked
/// for without a dossier) keeps the old shape: its marker is the plain text. A subtask row given a dossier
/// registers its own `kronos-subtask:` marker under the private type, like a task row.
enum DragOut {
    static let linkURLType = "public.url"
    static let richTextType = "public.rtf"
    static let plainTextType = "public.utf8-plain-text"

    /// A top-level task row's drag, dossier included. Call when the drag starts.
    @MainActor static func provider(task: KTask) -> NSItemProvider {
        provider(id: task.id, title: task.title, isChild: false,
                 dossier: TaskDragText.render(TaskDragText.Input(task: task)))
    }

    static func provider(id: UUID, title: String, isChild: Bool, dossier: String? = nil) -> NSItemProvider {
        let internalText = isChild ? DropZonePayloadReader.subtaskDragString(id) : DropZonePayloadReader.taskDragString(id)
        let provider: NSItemProvider
        if let dossier {
            provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: DropZonePayloadReader.dragItemTypeID, visibility: .all) { done in
                done(Data(internalText.utf8), nil); return nil
            }
            provider.registerDataRepresentation(forTypeIdentifier: plainTextType, visibility: .all) { done in
                done(Data(dossier.utf8), nil); return nil
            }
        } else {
            provider = NSItemProvider(object: internalText as NSString)
        }
        let link = TaskLink.string(for: id)
        if let rtf = richText(title: title, link: link) {
            provider.registerDataRepresentation(forTypeIdentifier: richTextType, visibility: .all) { done in
                done(rtf, nil); return nil
            }
        }
        provider.registerDataRepresentation(forTypeIdentifier: linkURLType, visibility: .all) { done in
            done(Data(link.utf8), nil); return nil
        }
        return provider
    }

    /// The title as RTF, the whole title being the Kronos link. Nil for an empty title.
    static func richText(title: String, link: String) -> Data? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = URL(string: link) else { return nil }
        let text = NSAttributedString(string: name, attributes: [.link: url])
        return try? text.data(from: NSRange(location: 0, length: text.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}
