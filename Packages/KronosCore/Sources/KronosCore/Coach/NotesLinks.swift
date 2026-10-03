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
/// A task can be linked to any dropped item — an Apple Note, a local
/// file, a web page, or an email — encoded as one `link://` line per attachment
/// in the task's notes text, alongside (and in the same style as) `NoteLink`'s
/// `notes://` line. Reading the linked item's CONTENT is not this type's job:
/// it only encodes and finds the reference. A file link stores a security-scoped
/// bookmark (as base64, since the carrier is plain text) plus a display path,
/// exactly like `ProjectFolderLink.finder` — resolving it is the app's job.
public struct ContextLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case appleNote
        case file
        /// A dropped directory: distinct from `.file`, which reveals in Finder instead of
        /// opening. Without this case, `ListDrop.swift` collapsed every folder drop into
        /// `.file` and the inspector's `open()` had no way to tell them apart.
        case folder
        case web
        /// An email message dragged from Apple Mail. Reference is a `message://` URL.
        case email
    }

    public let kind: Kind
    /// The Apple Note id (`.appleNote`), the web URL string (`.web`), the
    /// base64-encoded security-scoped bookmark (`.file`/`.folder`), or the
    /// `message://` URL (`.email`).
    public let reference: String
    /// Human-readable label — the note's title, the file's display path, or
    /// the web page's URL/title. Never resolved from `reference` by this
    /// type; the caller supplies whatever it already has.
    public let displayName: String
    /// Which device attached this link, as `DeviceOrigin.token`; nil for a link written before
    /// origins existed, and always nil for kinds that mean the same on every device (`.web`).
    /// A fourth `|` field of the line, so old three-field lines stay valid byte for byte.
    public let origin: String?

    public init(kind: Kind, reference: String, displayName: String, origin: String? = nil) {
        self.kind = kind
        self.reference = reference
        self.displayName = displayName
        self.origin = origin
    }

    /// True for links whose reference only resolves on the device that made them: a file or
    /// folder bookmark, a Mail message, an Apple Notes id. A web link works everywhere.
    public var isDeviceLocal: Bool { kind != .web }

    /// This link with `device` as its origin, when it is device-local and has none yet.
    /// A link that already has an origin keeps it (it was made elsewhere, or earlier).
    public func stamped(with device: DeviceOrigin?) -> ContextLink {
        guard isDeviceLocal, origin == nil, let device else { return self }
        return ContextLink(kind: kind, reference: reference, displayName: displayName, origin: device.token)
    }

    /// The name of the OTHER device this link belongs to ("MacBook Pro"), or nil when it is
    /// usable here: web link, no origin recorded, an origin that cannot be read, or this device.
    public func foreignDeviceName(on device: DeviceOrigin?) -> String? {
        guard isDeviceLocal, let origin, let device, let from = DeviceOrigin(token: origin), from.id != device.id else { return nil }
        return from.name
    }

    private static let scheme = "link://"

    /// One `link://<kind>|<displayName>|<reference>` line. `|` cannot appear
    /// in `displayName` or `reference` at parse time (see `escape`), so a
    /// name containing one is percent-escaped rather than corrupting the
    /// line's field count.
    public var encodedLine: String {
        let base = Self.scheme + kind.rawValue + "|" + Self.escape(displayName) + "|" + Self.escape(reference)
        guard let origin, !origin.isEmpty else { return base }
        return base + "|" + Self.escape(origin)
    }

    /// The first `link://` line's `ContextLink`, or nil when the text has
    /// none or the line is malformed (an old/foreign line is ignored rather
    /// than thrown).
    public static func find(in notesText: String) -> ContextLink? {
        findAll(in: notesText).first
    }

    /// Every `link://` line in order — a task (or subtask) carries any number of attachments.
    public static func findAll(in notesText: String) -> [ContextLink] {
        notesText.components(separatedBy: "\n").compactMap(parse)
    }

    /// One line -> link, or nil for any other / malformed line.
    private static func parse(_ rawLine: String) -> ContextLink? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(scheme) else { return nil }
        let parts = trimmed.dropFirst(scheme.count).components(separatedBy: "|")
        guard parts.count == 3 || parts.count == 4, let kind = Kind(rawValue: parts[0]) else { return nil }
        let origin = parts.count == 4 && !parts[3].isEmpty ? unescape(parts[3]) : nil
        return ContextLink(kind: kind, reference: unescape(parts[2]), displayName: unescape(parts[1]), origin: origin)
    }

    /// `notesText` without `link` (matched on kind + reference); every other line, other
    /// links included, is kept.
    public static func removing(_ link: ContextLink, from notesText: String) -> String {
        notesText.components(separatedBy: "\n")
            .filter { line in
                guard let l = parse(line) else { return true }
                return !(l.kind == link.kind && l.reference == link.reference)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appends this link as its own line; already attached (same kind + reference) -> unchanged.
    public func appending(to notesText: String) -> String {
        appending(to: notesText, device: DeviceOrigin.current)
    }

    /// `appending(to:)` with the stamping device given explicitly (nil = leave unstamped).
    public func appending(to notesText: String, device: DeviceOrigin?) -> String {
        if Self.findAll(in: notesText).contains(where: { $0.kind == kind && $0.reference == reference }) {
            return notesText
        }
        let line = stamped(with: device).encodedLine
        let trimmed = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : trimmed + "\n" + line
    }

    /// The four literal lines a broken build (28.09.2026) wrote instead of a `link://` line:
    /// its `encodedLine` had every `\(` turned into `\n(`. Nothing else ever produces them.
    static let corruptLines: Set<String> = [
        "(Self.scheme)", "(kind.rawValue)|", "(Self.escape(displayName))|", "(Self.escape(reference))",
    ]

    /// `notesText` without those lines (and the blank runs they leave); nil when there were none.
    public static func strippingCorruptLines(_ notesText: String) -> String? {
        let lines = notesText.components(separatedBy: "\n")
        guard lines.contains(where: { corruptLines.contains($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        var out: [String] = []
        for line in lines where !corruptLines.contains(line.trimmingCharacters(in: .whitespaces)) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%25", with: "%")
    }
}


// MARK: - Device origin

/// Who attached a device-local link. `id` is a short random id kept in this device's defaults
/// (stable across renames); `name` is only for display ("on MacBook Pro"). Both travel inside the
/// link line as `<id>~<name>`, so no schema field is needed.
public struct DeviceOrigin: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var token: String { id + "~" + name }

    /// nil for anything that is not `<id>~<name>` with a non-empty id.
    public init?(token: String) {
        guard let cut = token.firstIndex(of: "~"), cut != token.startIndex else { return nil }
        self.id = String(token[..<cut])
        let name = String(token[token.index(after: cut)...])
        self.name = name.isEmpty ? self.id : name
    }

    private static let defaultsKey = "kronos.device.id"

    /// The origin of this device: its persisted id (created on first use) and its display name.
    public static func live(defaults: UserDefaults = .standard, name: String = defaultName()) -> DeviceOrigin {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return DeviceOrigin(id: existing, name: name)
        }
        let fresh = String(UUID().uuidString.prefix(8)).lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return DeviceOrigin(id: fresh, name: name)
    }

    public static func defaultName() -> String {
        #if os(macOS)
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        #endif
        let host = ProcessInfo.processInfo.hostName
        let trimmed = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        return trimmed.isEmpty ? "Device" : trimmed
    }

    /// The device stamped onto new device-local links. nil until the app calls `configure`
    /// (so Core tests and snapshot runs never write origins by accident).
    public static var current: DeviceOrigin? {
        get { box.get() }
        set { box.set(newValue) }
    }

    public static func configureLive(defaults: UserDefaults = .standard) {
        current = live(defaults: defaults)
    }

    private static let box = OriginBox()
    private final class OriginBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DeviceOrigin?
        func get() -> DeviceOrigin? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: DeviceOrigin?) { lock.lock(); value = v; lock.unlock() }
    }
}
