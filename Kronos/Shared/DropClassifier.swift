// Kronos/Shared/DropClassifier.swift — pure mapping from a dropped
// pasteboard item's type identifiers + payload to a link kind, title and reference. No
// SwiftUI/AppKit import — only Foundation + UniformTypeIdentifiers — so this file compiles
// standalone in the G5 self-test (scripts/dropclassifier-selftest.swift) exactly as it does
// inside the app target. The caller (ListDrop.swift) reads an NSItemProvider's registered
// type identifiers and loads the matching representation; this type never touches the
// pasteboard itself.
//
// Apple Notes drags are undocumented (PLAN.md risk): classified defensively by a short list
// of known Notes type identifiers and by `notes://` / `applenotes:` URL schemes, and this
// NEVER fails a drop silently — anything unrecognised, or a Notes item with no usable payload,
// falls back to `.text` with the first line as its title (the UI then shows "Linked as text").
import Foundation
import UniformTypeIdentifiers

/// One dropped item, reduced to a link the app can store as a `ContextLink`
/// (KronosCore/Coach/AppleNotesBridge.swift). `title` is always non-empty (falls back to a
/// generic placeholder) so a chip never renders blank.
public struct DropClassification: Equatable, Sendable {
    public enum Kind: String, Sendable { case appleNote, file, folder, web, text }

    public let kind: Kind
    public let title: String
    /// The apple note id (`.appleNote`), the file/folder path (`.file`/`.folder`), the URL
    /// string (`.web`), or the raw text (`.text`).
    public let payload: String
    /// `.appleNote` only: true when `payload` is a real Notes id parsed from a
    /// `notes://`/`applenotes:` URL — the only case a caller can hand to
    /// `AppleNotesBridge.body(ofNoteID:)` and expect a real note back. False means `payload`
    /// is just the drag's title/text (macOS gave no usable identifier): a caller that needs a
    /// working link falls back to the manual "Link Apple note" picker instead of treating
    /// this string as an id. Always false for every other kind.
    public let isVerifiedID: Bool

    public init(kind: Kind, title: String, payload: String, isVerifiedID: Bool = false) {
        self.kind = kind
        self.title = title
        self.payload = payload
        self.isVerifiedID = isVerifiedID
    }
}

/// One pasteboard item as plain values: every type identifier it registers, plus whatever
/// payload was actually loaded for the identifiers this classifier recognises. `ListDrop`
/// builds this from an `NSItemProvider`; the self-test builds it by hand.
public struct DropItem: Sendable {
    public let typeIdentifiers: [String]
    /// A file URL's path, when a `public.file-url` (or subtype) representation was loaded.
    public let fileURLString: String?
    /// A plain URL string, when a `public.url` representation was loaded (also covers
    /// `notes://`/`applenotes:` custom-scheme URLs).
    public let urlString: String?
    /// Plain text, when a `public.plain-text`/`public.utf8-plain-text` representation was
    /// loaded — also the last-resort fallback source for a title.
    public let text: String?
    /// True when the filesystem item at `fileURLString` is a directory. Irrelevant for
    /// anything else.
    public let isDirectory: Bool

    public init(typeIdentifiers: [String], fileURLString: String? = nil, urlString: String? = nil,
                text: String? = nil, isDirectory: Bool = false) {
        self.typeIdentifiers = typeIdentifiers
        self.fileURLString = fileURLString
        self.urlString = urlString
        self.text = text
        self.isDirectory = isDirectory
    }
}

public enum DropClassifier {
    /// Notes.app registers drags under its own private UTI rather than a public one — this
    /// is the identifier observed on macOS 14/15 ("com.apple.notes.richtext" / plain
    /// "com.apple.notes"); either is treated as a Notes drag. Defensive: a future OS
    /// registering a different identifier still falls through to the URL/text checks below
    /// rather than crashing or silently dropping the item.
    static let knownNotesTypeIdentifiers: Set<String> = [
        "com.apple.notes.richtext", "com.apple.notes", "com.apple.notes.note",
    ]

    /// Classifies one dropped item. Never throws, never returns nil — an item this classifier
    /// cannot place more specifically becomes `.text` (a calm fallback the inspector shows as
    /// "Linked as text"), which is the plan's explicit "never fail a drop silently" rule.
    public static func classify(_ item: DropItem) -> DropClassification {
        if isNotesDrag(item) {
            return classifyNotes(item)
        }
        if let urlString = item.urlString, let noteID = noteID(fromURLString: urlString) {
            return DropClassification(kind: .appleNote, title: noteTitle(for: item) ?? noteID, payload: noteID, isVerifiedID: true)
        }
        // ROOT CAUSE of a real bug where a dropped Finder file rendered as a globe icon
        // titled "Untitled". `ListDrop.swift` asks for a file-URL representation and a
        // generic URL representation as two separate, concurrent loads
        // (`UTType.fileURL`/"public.file-url" vs `UTType.url`/"public.url"); a `file-url`
        // item conforms to `url` but not the reverse, so some drag sources hand back a
        // `file://…` string ONLY under `urlString`, leaving `fileURLString` nil. The old
        // code below only ever looked at `fileURLString` here, so that case fell through
        // the http(s)-only web check and landed on the empty-text fallback. Any `file://`
        // URL — from either field — is now a file link, never a `.web`/`.text` guess.
        // `item.isDirectory` is trusted as given either way (this classifier stays
        // filesystem-free, per its own file doc comment) — the caller (`ListDrop.swift`)
        // is the one place that actually stats the path, and it already does so for
        // whichever path it resolved before building this `DropItem`.
        let filePath = item.fileURLString ?? Self.filePath(fromURLString: item.urlString)
        if let path = filePath {
            let title = (path as NSString).lastPathComponent
            return DropClassification(kind: item.isDirectory ? .folder : .file, title: title.isEmpty ? path : title, payload: path)
        }
        if let urlString = item.urlString, let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" {
            return DropClassification(kind: .web, title: url.host.map { $0 + url.path } ?? urlString, payload: urlString)
        }
        // Last-resort fallback: any text, or (if truly nothing usable was loaded) an empty
        // pasteboard placeholder — the UI still shows a calm chip, never a crash.
        let text = item.text ?? item.urlString ?? ""
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let title = firstLine.trimmingCharacters(in: .whitespaces)
        return DropClassification(kind: .text, title: title.isEmpty ? "Untitled" : title, payload: text)
    }

    private static func isNotesDrag(_ item: DropItem) -> Bool {
        !knownNotesTypeIdentifiers.isDisjoint(with: Set(item.typeIdentifiers))
    }

    /// A Notes drag with no readable text still yields a stable link (the app can open Notes
    /// even without a title) rather than being discarded — the id substitutes as the title.
    private static func classifyNotes(_ item: DropItem) -> DropClassification {
        if let urlString = item.urlString, let id = noteID(fromURLString: urlString) {
            return DropClassification(kind: .appleNote, title: noteTitle(for: item) ?? id, payload: id, isVerifiedID: true)
        }
        if let text = item.text, let title = noteTitle(for: item) {
            return DropClassification(kind: .appleNote, title: title, payload: text)
        }
        return DropClassification(kind: .appleNote, title: noteTitle(for: item) ?? "Apple Note", payload: item.text ?? "")
    }

    /// The filesystem path of `s` when it is a `file://` URL, else nil — used to catch a
    /// file drag that only surfaced as a generic URL representation (see `classify`'s
    /// root-cause comment above).
    private static func filePath(fromURLString s: String?) -> String? {
        guard let s, let url = URL(string: s), url.isFileURL else { return nil }
        return url.path
    }

    /// `notes://` and `applenotes:` are the two schemes Apple Notes' own share sheet and
    /// drag payload are documented (informally) to emit.
    private static func noteID(fromURLString s: String) -> String? {
        if s.hasPrefix("notes://") { return String(s.dropFirst("notes://".count)) }
        if s.hasPrefix("applenotes:") { return String(s.dropFirst("applenotes:".count)) }
        return nil
    }

    private static func noteTitle(for item: DropItem) -> String? {
        guard let text = item.text else { return nil }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
