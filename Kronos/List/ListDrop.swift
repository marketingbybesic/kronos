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

/// One task-scoped drop target: attach as `.kContextLinkDrop(task:model:)` on a row, the Now
/// card or the inspector header. Shows a brief hover highlight while something draggable is
/// over it; the actual link write happens once the drop completes.
struct ContextLinkDropModifier: ViewModifier {
    let taskID: UUID
    let model: AppModel
    @State private var isTargeted = false

    private static let acceptedTypes: [UTType] = [.fileURL, .url, .plainText, .text, .item]

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Tok.borderActive, style: StrokeStyle(lineWidth: Metrics.strokeQuiet, dash: [Space.x1, Space.x1]))
                }
            }
            .onDrop(of: Self.acceptedTypes, isTargeted: $isTargeted) { providers in
                // Tried FIRST, synchronously, before the drag session can be torn down: the
                // reliable AppKit route for a live Finder drag (the NSItemProvider path below
                // was silently loading nothing for real drops). `FileDropPasteboard.fileURLs`
                // takes the pasteboard as a parameter so the self-test can hand it a private
                // named pasteboard instead of the real system drag pasteboard.
                if let url = FileDropPasteboard.fileURLs(from: NSPasteboard(name: .drag)).first {
                    Self.write(FileDropPasteboard.fields(for: url).contextLink, taskID: taskID, model: model)
                    return true
                }
                guard let provider = providers.first else { return false }
                Task { await Self.classify(provider) { link in
                    Self.write(link, taskID: taskID, model: model)
                } }
                return true
            }
    }

    /// Never writes a link with an empty reference: an empty-text `DropClassifier` fallback
    /// used to reach here and get stored as `link://web|Untitled|` — a chip that can never
    /// open. Nothing usable loaded -> nothing is written; the
    /// existing debug type-identifier logger (`NotesDropPasteboardLog`, Kronos/Links/) is the
    /// place to look at what the source actually offered.
    private static func write(_ link: ContextLink, taskID: UUID, model: AppModel) {
        guard !link.reference.isEmpty else { return }
        model.store.update(taskID) { $0.notes = link.appending(to: $0.notes) }
        model.didMutate()
    }

    /// Loads whichever representations `provider` actually offers, builds a `DropItem`, runs
    /// it through `DropClassifier`, and hands the resulting `ContextLink` to `apply` on the
    /// main actor. Every recognised representation is attempted (not just the first) because
    /// a Notes drag registers several type identifiers at once and the richest one (plain
    /// text, for a real title) is not always first in `provider.registeredTypeIdentifiers`.
    /// Fallback path only — `body(content:)` tries the drag pasteboard directly first, since
    /// this NSItemProvider route is the one that was silently loading nothing live (see file
    /// doc comment).
    static func classify(_ provider: NSItemProvider, apply: @escaping (ContextLink) -> Void) async {
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
        let classification = DropClassifier.classify(item)
        let link = contextLink(from: classification)
        await MainActor.run { apply(link) }
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
        modifier(ContextLinkDropModifier(taskID: taskID, model: model))
    }
}

extension FileDropPasteboard.Fields {
    /// The one place this file converts the KronosCore-free `Fields` into the real
    /// `ContextLink` it stores.
    var contextLink: ContextLink {
        ContextLink(kind: isDirectory ? .folder : .file, reference: reference, displayName: displayName)
    }
}
