// Coach/NotesLinks.swift — split out of AppleNotesBridge.swift, which went over the
// project's 500-line cap after adding `open(noteID:)`. `NoteLink`/`ContextLink` are pure
// text-encoding types with no dependency on the osascript machinery in that file, so they
// move here unchanged (same package, same import, same public API — no caller needed
// a change).
import Foundation

// MARK: - Note links (feature F.3)

/// Encodes/finds a `notes://<id>` line inside a task's notes text, so a task
/// can be linked to an Apple Note without a new stored field.
public enum NoteLink {
    private static let scheme = "notes://"

    /// A line to append to a task's notes text, linking it to `noteID`.
    public static func line(for noteID: String) -> String { scheme + noteID }

    /// The first linked note id found in `notesText`, or nil.
    public static func find(in notesText: String) -> String? {
        for line in notesText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(scheme) {
                let id = String(trimmed.dropFirst(scheme.count))
                return id.isEmpty ? nil : id
            }
        }
        return nil
    }

    /// Appends a link line to `notesText`, replacing any existing link
    /// (a task links to at most one note at a time) rather than accumulating
    /// duplicates across re-linking.
    public static func appending(_ noteID: String, to notesText: String) -> String {
        let withoutExisting = notesText
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(scheme) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutExisting.isEmpty ? line(for: noteID) : withoutExisting + "\n" + line(for: noteID)
    }
}

// MARK: - Context links (any dropped item, not just a note)

/// A task can be linked to any one dropped item — an Apple Note, a local
/// file, or a web page — encoded as one `link://` line in the task's notes
/// text, alongside (and in the same style as) `NoteLink`'s `notes://` line.
/// Reading the linked item's CONTENT is not this type's job: it only encodes
/// and finds the reference. A file link stores a security-scoped bookmark
/// (as base64, since the carrier is plain text) plus a display path, exactly
/// like `ProjectFolderLink.finder` — resolving it is the app's job.
public struct ContextLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case appleNote
        case file
        /// A dropped directory: distinct from `.file`, which reveals in Finder instead of
        /// opening. Without this case, `ListDrop.swift` collapsed every folder drop into
        /// `.file` and the inspector's `open()` had no way to tell them apart.
        case folder
        case web
    }

    public let kind: Kind
    /// The Apple Note id (`.appleNote`), the web URL string (`.web`), or the
    /// base64-encoded security-scoped bookmark (`.file`/`.folder`).
    public let reference: String
    /// Human-readable label — the note's title, the file's display path, or
    /// the web page's URL/title. Never resolved from `reference` by this
    /// type; the caller supplies whatever it already has.
    public let displayName: String

    public init(kind: Kind, reference: String, displayName: String) {
        self.kind = kind
        self.reference = reference
        self.displayName = displayName
    }

    private static let scheme = "link://"

    /// One `link://<kind>|<displayName>|<reference>` line. `|` cannot appear
    /// in `displayName` or `reference` at parse time (see `escape`), so a
    /// name containing one is percent-escaped rather than corrupting the
    /// line's field count.
    public var encodedLine: String {
        "\(Self.scheme)\(kind.rawValue)|\(Self.escape(displayName))|\(Self.escape(reference))"
    }

    /// The first `link://` line's `ContextLink`, or nil when the text has
    /// none or the line is malformed (an old/foreign line is ignored rather
    /// than thrown).
    public static func find(in notesText: String) -> ContextLink? {
        for rawLine in notesText.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(scheme) else { continue }
            let body = String(trimmed.dropFirst(scheme.count))
            let parts = body.components(separatedBy: "|")
            guard parts.count == 3, let kind = Kind(rawValue: parts[0]) else { continue }
            return ContextLink(kind: kind, reference: unescape(parts[2]), displayName: unescape(parts[1]))
        }
        return nil
    }

    /// Appends this link to `notesText`, replacing any existing `link://`
    /// line — a task carries at most one context link at a time, matching
    /// `NoteLink.appending`'s replace-not-accumulate behaviour.
    public func appending(to notesText: String) -> String {
        let withoutExisting = notesText
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(Self.scheme) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutExisting.isEmpty ? encodedLine : withoutExisting + "\n" + encodedLine
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "|", with: "%7C")
         .replacingOccurrences(of: "\n", with: "%0A")
    }
    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "%0A", with: "\n").replacingOccurrences(of: "%7C", with: "|")
         .replacingOccurrences(of: "%25", with: "%")
    }
}
