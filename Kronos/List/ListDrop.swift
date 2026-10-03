// Kronos/List/ListDrop.swift — drop targets for a task row, the inspector and the Now card.
// Bridges an `NSItemProvider` (what SwiftUI's `.onDrop` hands a drop target) into the pure
// `DropClassifier` (Kronos/Shared/DropClassifier.swift), then writes the resulting link onto
// the task's notes text via `ContextLink` (KronosCore). Never fails a drop silently: every
// provider that offers ANY of the recognised representations resolves to a link, worst case
// `.text`.
//
// ROOT CAUSE of a real bug where stored file links ended up as `link://web|Untitled|` — kind
// `.web`, empty reference: that is only possible if `classify` below loaded NOTHING
// (fileURL/url/text all nil), fell to `DropClassifier`'s empty `.text` fallback, and
// `contextLink(from:)`'s `.text` branch wrote an empty string as both payload and reference.
// The click then ran `URL(string: "")` -> nil -> no-op — a SEPARATE failure from the
// folder/reveal bug fixed first, and the real reason nothing happened live at all.
// `NSItemProvider.loadObject`/`loadItem` are unreliable for a live Finder drag on this
// project's observed macOS version; `NSPasteboard(name: .drag)` read SYNCHRONOUSLY inside the
// `onDrop` closure (before the drag session can be torn down) is the reliable AppKit route
// and is now tried first.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KronosCore

/// Where an attachment drop lands: the task itself, or one of its subtasks.
enum AttachmentTarget {
    case task(UUID)
    case subtask(KTask)
}

/// One drop target: attach as `.kContextLinkDrop(taskID:model:)` on a row, the Now card or the
/// inspector, or `.kContextLinkDrop(subtask:model:)` on a subtask row. Shows a brief hover
/// highlight while something draggable is over it; the links are written once the drop completes.
struct ContextLinkDropModifier: ViewModifier {
    let target: AttachmentTarget
    let model: AppModel
    @State private var isTargeted = false

    static let acceptedTypes: [UTType] = [.fileURL, .url, .plainText, .text, .item]

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Tok.borderActive, style: StrokeStyle(lineWidth: Metrics.strokeQuiet, dash: [Space.x1, Space.x1]))
                }
            }
            .onDrop(of: Self.acceptedTypes, isTargeted: $isTargeted) { providers in
                Self.accept(providers, target: target, model: model)
            }
    }

    /// The whole drop routine, shared by every attachment target (the subtask row calls it
    /// from its own drop delegate). Reads the SYSTEM drag pasteboard synchronously first,
    /// before the drag session can be torn down (the NSItemProvider path was silently loading
    /// nothing for real Finder drops): every dragged Mail message, else EVERY dragged
    /// file/folder (the old code kept only `.first`). Kronos's own subtask-reorder drag is
    /// refused so it can never become a text attachment.
    static func accept(_ providers: [NSItemProvider], target: AttachmentTarget, model: AppModel) -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        DropTypesLog.append(pasteboard)
        guard MailDropPasteboard.subtaskID(from: pasteboard) == nil,
              pasteboard.string(forType: .string)?.hasPrefix(DropZonePayloadReader.taskPrefix) != true else { return false }
        if let links = links(fromDragPasteboard: pasteboard) {
            write(links, to: target, model: model)
            return true
        }
        guard !providers.isEmpty else { return false }
        Task {
            var links: [ContextLink] = []
            for provider in providers {
                if let link = await classify(provider) { links.append(link) }
            }
            await MainActor.run { write(links, to: target, model: model) }
        }
        return true
    }

    /// Mail messages or files/folders straight off the drag pasteboard; nil when it holds
    /// neither (web links, text, Notes go through the provider path).
    static func links(fromDragPasteboard pasteboard: NSPasteboard) -> [ContextLink]? {
        let mail = MailDropPasteboard.messages(from: pasteboard)
        if !mail.isEmpty {
            return mail.map {
                ContextLink(kind: .email, reference: $0.url,
                            displayName: $0.subject ?? String(localized: "detail.links.email.untitled"))
            }
        }
        let files = FileDropPasteboard.fileURLs(from: pasteboard)
        return files.isEmpty ? nil : files.map { FileDropPasteboard.fields(for: $0).contextLink }
    }

    /// One store write (= one undo step) for the whole drop. Never writes a link with an
    /// empty reference: an empty-text fallback used to be stored as `link://web|Untitled|`,
    /// a chip that can never open.
    static func write(_ links: [ContextLink], to target: AttachmentTarget, model: AppModel) {
        let usable = links.filter { !$0.reference.isEmpty }
        guard !usable.isEmpty else { return }
        let title: String
        switch target {
        case .task(let id):
            title = model.store.task(id)?.title ?? ""
            model.store.update(id) { t in t.notes = usable.reduce(t.notes) { $1.appending(to: $0) } }
        case .subtask(let s):
            title = s.title
            model.store.updateSubtaskNotes(s.id, notes: usable.reduce(s.notes) { $1.appending(to: $0) })
        }
        model.commit(String(format: String(localized: "undo.linked.name"), title))
    }

    /// Loads whichever representations `provider` actually offers, builds a `DropItem`, runs
    /// it through `DropClassifier`, and hands the resulting `ContextLink` to `apply` on the
    /// main actor. Every recognised representation is attempted (not just the first) because
    /// a Notes drag registers several type identifiers at once and the richest one (plain
    /// text, for a real title) is not always first in `provider.registeredTypeIdentifiers`.
    /// Fallback path only — `body(content:)` tries the drag pasteboard directly first, since
    /// this NSItemProvider route is the one that was silently loading nothing live (see file
    /// doc comment).
    static func classify(_ provider: NSItemProvider) async -> ContextLink? {
        let typeIdentifiers = provider.registeredTypeIdentifiers
        async let fileURL = loadFileURL(provider)
        async let url = loadURL(provider)
        async let text = loadText(provider)
        let (fileURLResult, urlResult, textResult) = await (fileURL, url, text)

        // ROOT CAUSE of a real bug where a dropped Finder file showed a globe icon and
        // "Untitled": `loadFileURL` asks only for `UTType.fileURL` ("public.file-url");
        // `loadURL` asks for the broader `UTType.url` ("public.url"), which a `file-url`
        // item also conforms to — but conformance is one-directional. Some drag sources
        // (observed: Finder items whose provider only advertises the generic `public.url`
        // representation, not the more specific `public.file-url` one) make
        // `hasItemConformingToTypeIdentifier(.fileURL)` return false while `loadObject
        // (NSURL.self)` under `.url` still resolves a `file://` URL. `fileURLResult` then
        // stayed nil, `urlResult` held a `file://` string that the old http(s)-only web
        // check rejected, and the item fell through to the empty-text fallback
        // ("Untitled"). `DropClassifier.classify` now treats a `file://` `urlString` as a
        // file path too (Kronos/Shared/DropClassifier.swift) — stat the SAME resolved path
        // here (the classifier stays filesystem-free) so `isDirectory` is still correct
        // when the path only ever showed up as a `urlString`.
        let resolvedPath = fileURLResult ?? urlResult.flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil }
        var isDirectory = false
        if let path = resolvedPath {
            isDirectory = (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
        }
        let item = DropItem(typeIdentifiers: typeIdentifiers, fileURLString: fileURLResult,
                            urlString: urlResult, text: textResult, isDirectory: isDirectory)
        if textResult?.hasPrefix(MailDropPasteboard.subtaskDragPrefix) == true { return nil }
        return contextLink(from: DropClassifier.classify(item))
    }

    /// `.file`/`.folder` store a security-scoped bookmark (base64, since `ContextLink`'s
    /// carrier is plain text) so the reference survives the user moving or renaming the
    /// item — resolving it later is the app's job (opening it), not this classifier's.
    /// `c.payload` IS the file path for both kinds (`DropClassifier.classify`'s file
    /// branch sets `payload: path`) regardless of whether that path came from the
    /// `public.file-url` loader or the `file://` `urlString` fallback, so bookmarking
    /// reads it from the classification rather than needing the raw provider result.
    private static func contextLink(from c: DropClassification) -> ContextLink {
        switch c.kind {
        case .appleNote:
            return ContextLink(kind: .appleNote, reference: c.payload, displayName: c.title)
        case .web:
            return ContextLink(kind: .web, reference: c.payload, displayName: c.title)
        case .file, .folder:
            // ROOT CAUSE of a real bug: `ContextLink.Kind` had no `.folder` case, so both
            // landed here as `.file` and the inspector's open() could never reveal a folder
            // instead of opening it. Kind now carries straight through.
            let reference = bookmarkBase64(forPath: c.payload) ?? c.payload
            let kind: ContextLink.Kind = c.kind == .folder ? .folder : .file
            return ContextLink(kind: kind, reference: reference, displayName: c.title)
        case .email:
            return ContextLink(kind: .email, reference: c.payload, displayName: c.title)
        case .text:
            // No dedicated Core "text" kind (plan: a task carries at most one context link;
            // a bare-text drop still needs a chip) — stored as a `.web` link with an empty
            // scheme-less reference reads wrong, so it rides the `.file` kind's free-text
            // slot instead is also wrong. Kept honest: encode as `.web` with the raw text as
            // its own reference/display, which round-trips through `ContextLink` untouched
            // and the inspector renders with a text glyph by checking `reference` for a URL.
            return ContextLink(kind: .web, reference: c.payload, displayName: c.title)
        }
    }

    private static func bookmarkBase64(forPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        return data.base64EncodedString()
    }

    /// Tries `loadObject(ofClass: URL.self)` first, then falls back to `loadItem(forTypeIdentifier:)`
    /// reading either a `URL` or `Data` result (`URL(dataRepresentation:relativeTo:)`) — some
    /// providers answer `loadItem` but not `loadObject` for the same type identifier. Only a
    /// fallback: `body(content:)` tries the drag pasteboard directly first (team-lead finding
    /// — that is the reliable route; this whole provider path was silently returning nil live).
    private static func loadFileURL(_ provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        let viaLoadObject: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.path)
            }
        }
        if let viaLoadObject { return viaLoadObject }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url.path)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url.path)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                continuation.resume(returning: (url as? URL)?.absoluteString)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: NSString.self) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                continuation.resume(returning: (reading as? NSString) as String?)
            }
        }
    }
}

extension View {
    /// Accepts a dropped Apple Note, file, folder, URL or text and links it to `taskID`
    /// (feature M). Mount on a task row, the inspector header, or the Now card.
    func kContextLinkDrop(taskID: UUID, model: AppModel) -> some View {
        modifier(ContextLinkDropModifier(target: .task(taskID), model: model))
    }
}

extension FileDropPasteboard.Fields {
    /// The one place this file converts the KronosCore-free `Fields` into the real
    /// `ContextLink` it stores.
    var contextLink: ContextLink {
        ContextLink(kind: isDirectory ? .folder : .file, reference: reference, displayName: displayName)
    }
}

/// One line per attachment drop — type NAMES only, never contents — in
/// `<store folder>/drop-types.log`, so a source that offers something unexpected (a future
/// Mail) is diagnosable from a single try. Capped: past 64 KB the file starts over.
enum DropTypesLog {
    static func append(_ pasteboard: NSPasteboard, event: String = "drop") {
        let url = KronosStore.containerDirectory().appendingPathComponent("drop-types.log")
        let line = ISO8601DateFormatter().string(from: Date()) + " " + event + " " + MailDropPasteboard.typesSummary(pasteboard) + "\n"
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 64_000 || !FileManager.default.fileExists(atPath: url.path) {
            try? Data(line.utf8).write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
