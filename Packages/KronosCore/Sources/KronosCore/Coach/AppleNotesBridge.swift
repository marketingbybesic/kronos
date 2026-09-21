// Coach/AppleNotesBridge.swift — read-only Apple Notes access for Capture
// ("From Apple Notes"), the "Kronos" inbox folder, and note links from a
// task/project.
//
// Security: AppleScript is passed to `/usr/bin/osascript` as a `-e` ARGUMENT
// via `Process.arguments`, never interpolated into a shell string and never
// run through `/bin/sh -c`. Every script embeds at most a folder/note NAME
// the app already has from a prior `osascript` call (never raw user
// keystrokes), and that name is escaped for AppleScript string literals
// before insertion. A hard 8 s timeout kills the process. Note CONTENT is
// never logged — only counts and ids ever reach a log line.
//
// `NoteLink`/`ContextLink` (the notes:// / link:// text-encoding types) live in
// Coach/NotesLinks.swift — split out to keep this file under the project's
// 500-line cap after adding `open(noteID:)`.

import Foundation

// MARK: - Protocol

/// One Apple Note folder.
public struct NoteFolderInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// One Apple Note's metadata (not its body — `body(ofNoteID:)` fetches that
/// separately so listing a folder stays cheap).
public struct NoteInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let modifiedAt: Date
    public init(id: String, title: String, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.modifiedAt = modifiedAt
    }
}

public enum NotesError: Error, Equatable, Sendable {
    /// The user has not granted (or has denied) Automation access to Notes —
    /// osascript error -1743. The caller shows "Allow access in System
    /// Settings", never a crash or a retry loop (PLAN.md risks).
    case notAuthorised
    case timedOut
    case notesAppUnavailable
    /// AppleScript's "can't get element" (-1728) when asking for a named
    /// folder/note that does not exist — distinct from `.notAuthorised` so
    /// callers can say "no folder named X" instead of "no permission".
    case notFound
    case unexpected(String)
}

/// Read-only Apple Notes access. `OsaScriptNotesBridge` implements this for
/// the app; `FixtureNotesBridge` is the in-memory double for tests and other
/// leaves. No AppleScript, `Process`, or osascript type appears outside
/// `OsaScriptNotesBridge`'s own file.
public protocol AppleNotesBridge: Sendable {
    func folders() async throws -> [NoteFolderInfo]
    func notes(inFolder folderName: String) async throws -> [NoteInfo]
    func body(ofNoteID noteID: String) async throws -> String
    /// Brings Notes.app forward on the linked note. `id of note` returns an
    /// `x-coredata://` URL that is NOT the `applenotes://showNote?identifier=` UUID — there is
    /// no documented transform between the two — so opening a specific note only works through
    /// AppleScript's own `show note id "<id>"`, never a constructed URL. A user-initiated call
    /// only (a click on "Open note"/"Otvori bilješku"), same as every other method here.
    func open(noteID: String) async throws
    /// Every note (across every account, like `folders()`) whose title EXACTLY matches
    /// `title`, supporting a text-only Notes drag: the first non-empty line of the dropped
    /// text becomes an exact-title lookup. Zero, one, or several results; the caller decides
    /// what to do with each count. Only reached from a real drop, and only when Notes
    /// automation is already granted (the caller checks `NotesPermissionReader` first — this
    /// method itself still triggers the OS prompt on a cold call like every other method
    /// here, so callers gate it, not this protocol).
    func noteIDs(titled title: String) async throws -> [NoteInfo]
}

// MARK: - osascript implementation

/// Runs AppleScript via `/usr/bin/osascript`, one `Process` per call, with
/// the script text passed as a `-e` argument (never a shell string). The
/// app is unsandboxed, so this needs `NSAppleEventsUsageDescription` in
/// Info.plist; the first call triggers the macOS Automation consent prompt.
public final class OsaScriptNotesBridge: AppleNotesBridge {
    private let timeoutSeconds: TimeInterval
    private let executableURL: URL

    /// - Parameters:
    ///   - timeoutSeconds: hard kill timeout (spec: 8 s).
    ///   - executableURL: overridable only so a test could point at a stub
    ///     binary; production always uses `/usr/bin/osascript`.
    public init(timeoutSeconds: TimeInterval = 8, executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.timeoutSeconds = timeoutSeconds
        self.executableURL = executableURL
    }

    public func folders() async throws -> [NoteFolderInfo] {
        // Two bugs used to stack into a silent "0 folders" result with no permission prompt.
        // (1) `folders` unqualified only walks the default account's folders on some setups —
        // this app must see every iCloud/On My Mac/IMAP account, so it iterates `accounts`
        // explicitly (Notes' documented way to do this), matching every account rather than
        // hoping the default one is iCloud. (2) `return out` used to hand osascript a LIST,
        // and osascript's default list->stdout coercion joins items with ", " on ONE line, not
        // one line per item — so a vault with 50+ folders produced a single comma-joined line
        // with 50+ tab characters in it. `runList`'s `parts.count == 2` guard then rejected
        // that one malformed "line" and returned an empty array without ever throwing. Fix:
        // set `text item delimiters` to a real linefeed and coerce the list to a STRING inside
        // the script, so the boundary between records is unambiguous before it ever reaches
        // Swift, regardless of how many folders or accounts exist.
        let script = """
        tell application "Notes"
            set AppleScript's text item delimiters to linefeed
            set out to {}
            repeat with acc in accounts
                repeat with f in folders of acc
                    set end of out to (id of f as string) & "\\t" & (name of f as string)
                end repeat
            end repeat
            set joined to out as string
            set AppleScript's text item delimiters to ""
            return joined
        end tell
        """
        let lines = try await runList(script)
        return lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { return nil }
            return NoteFolderInfo(id: parts[0], name: parts[1])
        }
    }

    public func notes(inFolder folderName: String) async throws -> [NoteInfo] {
        let escaped = Self.escapeForAppleScript(folderName)
        // Same linefeed-join fix as `folders()`; also searches every account
        // for a folder with this name (first match), not just the default
        // account, so the configured inbox folder is found under iCloud too.
        let script = """
        tell application "Notes"
            set AppleScript's text item delimiters to linefeed
            set out to {}
            set theFolder to missing value
            repeat with acc in accounts
                repeat with f in folders of acc
                    if (name of f as string) = "\(escaped)" then
                        set theFolder to f
                        exit repeat
                    end if
                end repeat
                if theFolder is not missing value then exit repeat
            end repeat
            if theFolder is missing value then
                error "Can't get folder \\"\(escaped)\\"." number -1728
            end if
            repeat with n in notes of theFolder
                set end of out to (id of n as string) & "\\t" & (name of n as string) & "\\t" & ((modification date of n) as string)
            end repeat
            set joined to out as string
            set AppleScript's text item delimiters to ""
            return joined
        end tell
        """
        let lines = try await runList(script)
        return lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3 else { return nil }
            let date = Self.appleDateFormatter.date(from: parts[2]) ?? Date(timeIntervalSince1970: 0)
            return NoteInfo(id: parts[0], title: parts[1], modifiedAt: date)
        }
    }

    public func body(ofNoteID noteID: String) async throws -> String {
        let escaped = Self.escapeForAppleScript(noteID)
        let script = """
        tell application "Notes"
            return body of note id "\(escaped)"
        end tell
        """
        let html = try await run(script)
        return NoteHTML.plainText(from: html)
    }

    public func noteIDs(titled title: String) async throws -> [NoteInfo] {
        // A note title from a text drag could in principle be enormous (the whole dropped
        // text if it had no newline); capped at 200 chars before it ever reaches AppleScript,
        // since no real Notes title is longer than this.
        let capped = String(title.prefix(200))
        let escaped = Self.escapeForAppleScript(capped)
        // Same linefeed-join + multi-account pattern as `folders()`/`notes(inFolder:)`:
        // `whose name is "..."` searches every note in every account for this one folder-less
        // query, not just one folder — the drop could be from any note in any account.
        let script = """
        tell application "Notes"
            set AppleScript's text item delimiters to linefeed
            set out to {}
            repeat with acc in accounts
                repeat with n in (notes of acc whose name is "\(escaped)")
                    set end of out to (id of n as string) & "\\t" & (name of n as string) & "\\t" & ((modification date of n) as string)
                end repeat
            end repeat
            set joined to out as string
            set AppleScript's text item delimiters to ""
            return joined
        end tell
        """
        let lines = try await runList(script)
        return lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3 else { return nil }
            let date = Self.appleDateFormatter.date(from: parts[2]) ?? Date(timeIntervalSince1970: 0)
            return NoteInfo(id: parts[0], title: parts[1], modifiedAt: date)
        }
    }

    public func open(noteID: String) async throws {
        let escaped = Self.escapeForAppleScript(noteID)
        // `show note id` also activates Notes.app on the shown note — no separate
        // `NSWorkspace.open` needed, and no `applenotes://showNote?identifier=` URL, which
        // cannot be built from this `x-coredata://` id.
        let script = """
        tell application "Notes"
            show note id "\(escaped)"
            activate
        end tell
        """
        _ = try await run(script)
    }

    // MARK: - Process plumbing

    /// Splits the script's stdout on real newlines. This ONLY works because
    /// every script that calls `runList` sets `AppleScript's text item
    /// delimiters to linefeed` and coerces its result list `as string`
    /// itself before returning — osascript's OWN default list->stdout
    /// coercion joins items with ", " on a single line (a 50-folder vault
    /// comes back as one comma-joined line with 50+ tab characters in it
    /// otherwise), which is the bug that made `folders()` silently
    /// return `[]` instead of throwing. Do not pass a bare `return out` list
    /// to this helper.
    private func runList(_ script: String) async throws -> [String] {
        let text = try await run(script)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func run(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["-e", script]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let box = ResumeOnce(continuation)

            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    box.resume(.success(out.trimmingCharacters(in: .newlines)))
                } else {
                    box.resume(.failure(NotesBridgeErrorMapper.map(stderr: err, status: proc.terminationStatus)))
                }
            }

            do {
                try process.run()
            } catch {
                box.resume(.failure(NotesError.notesAppUnavailable))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if process.isRunning {
                    process.terminate()
                    box.resume(.failure(NotesError.timedOut))
                }
            }
        }
    }

    /// Escapes a value that is about to be embedded inside a double-quoted
    /// AppleScript string literal: backslashes first (so an already-escaped
    /// sequence is not double-escaped), then quotes. This is defence in depth
    /// — every caller in this file only ever passes a folder/note name or id
    /// osascript itself returned — not a substitute for the `-e`-argument
    /// discipline that keeps this out of a shell entirely.
    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let appleDateFormatter: DateFormatter = {
        // AppleScript's default `date as string` coercion is locale/region
        // dependent; this bridge only uses the parsed date for sort/display
        // fallback, never for logic, so a failed parse degrading to epoch is
        // acceptable (see `notes(inFolder:)` above).
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()
}

/// Resumes a `CheckedContinuation` at most once. `Process.terminationHandler`
/// and the timeout's `asyncAfter` both race to resume the same continuation;
/// this box makes that race safe and gives the compiler a `Sendable` type to
/// capture instead of a bare local closure over shared mutable state.
private final class ResumeOnce: @unchecked Sendable {
    private let continuation: CheckedContinuation<String, Error>
    private let lock = NSLock()
    private var didResume = false

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func resume(_ result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}

/// Maps osascript's stderr to the errors callers must distinguish: -1743
/// ("not authorised" — Automation access denied/not yet granted) and -1728
/// ("can't get element" — e.g. `folder "X"` where X does not exist) are never
/// folded into a generic failure or an empty result, so the UI can tell
/// "Kronos has no permission to read Notes" apart from "No folder named X".
enum NotesBridgeErrorMapper {
    static func map(stderr: String, status: Int32) -> NotesError {
        if stderr.contains("-1743") { return .notAuthorised }
        if stderr.contains("-1728") { return .notFound }
        if stderr.contains("-600") { return .notesAppUnavailable }
        return .unexpected(stderr.isEmpty ? "osascript exited \(status)" : stderr)
    }
}

// MARK: - HTML -> plain text

/// Apple Notes stores a note's body as HTML. `AppleNotesBridge` only ever
/// hands callers plain text: strip tags, decode the handful of entities
/// Notes actually emits, and keep paragraph/list structure as line breaks
/// and bullets rather than collapsing everything to one line.
public enum NoteHTML {
    public static func plainText(from html: String) -> String {
        var s = html
        // Block-level and list boundaries become line breaks / bullets before
        // tags are stripped, so structure survives as whitespace.
        s = s.replacingOccurrences(of: "(?i)<li[^>]*>", with: "\u{2022} ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(div|p|h[1-6]|li|br)\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Collapse runs of 3+ blank lines and trim trailing spaces per line,
        // without destroying intentional single blank lines between paragraphs.
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append(line) }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        let map: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        var out = s
        for (entity, replacement) in map {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }
}

// MARK: - Fixture double

/// In-memory `AppleNotesBridge` for tests and other leaves. Never touches
/// osascript, Notes.app, or the filesystem.
public final class FixtureNotesBridge: AppleNotesBridge, @unchecked Sendable {
    public var stubFolders: [NoteFolderInfo]
    public var stubNotesByFolder: [String: [NoteInfo]]
    public var stubBodiesByID: [String: String]
    /// Keyed by exact title, matching `noteIDs(titled:)`'s own exact-match contract.
    public var stubNotesByTitle: [String: [NoteInfo]]
    public var errorToThrow: NotesError?

    public init(folders: [NoteFolderInfo] = [],
                notesByFolder: [String: [NoteInfo]] = [:],
                bodiesByID: [String: String] = [:],
                notesByTitle: [String: [NoteInfo]] = [:],
                errorToThrow: NotesError? = nil) {
        self.stubFolders = folders
        self.stubNotesByFolder = notesByFolder
        self.stubBodiesByID = bodiesByID
        self.stubNotesByTitle = notesByTitle
        self.errorToThrow = errorToThrow
    }

    public func folders() async throws -> [NoteFolderInfo] {
        if let e = errorToThrow { throw e }
        return stubFolders
    }

    public func notes(inFolder folderName: String) async throws -> [NoteInfo] {
        if let e = errorToThrow { throw e }
        return stubNotesByFolder[folderName] ?? []
    }

    public func body(ofNoteID noteID: String) async throws -> String {
        if let e = errorToThrow { throw e }
        return stubBodiesByID[noteID] ?? ""
    }

    /// Records the last id an `open(noteID:)` call was made with — tests assert on this
    /// rather than the fixture actually doing anything (it never touches osascript).
    public private(set) var lastOpenedNoteID: String?

    public func open(noteID: String) async throws {
        if let e = errorToThrow { throw e }
        lastOpenedNoteID = noteID
    }

    public func noteIDs(titled title: String) async throws -> [NoteInfo] {
        if let e = errorToThrow { throw e }
        return stubNotesByTitle[String(title.prefix(200))] ?? []
    }
}
