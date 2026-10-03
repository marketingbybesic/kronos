// Kronos/App/URLScheme.swift
// Pure parser for the `kronos://` URL scheme. Foundation only, on purpose: scripts/urlscheme-selftest.swift
// compiles THIS file with a hand-written table, so the shipped parser is the one proven.
//
//   kronos://add?title=…&notes=…&project=…&due=today|tomorrow|YYYY-MM-DD
//   kronos://open?id=<uuid>
//   kronos://quickadd
//   kronos://capture?text=…
//   kronos://impuls
//   kronos://complete?id=<uuid>
//   kronos://search?q=…
//   kronos://scope?name=inbox|today|next7|waiting|someday|all   or   kronos://scope?project=<name>
//
// `add`, `complete` and `open` also take `x-success=<url>`: once the action ran, that URL is opened with
// `id` (and `title`) appended, so a Shortcut or another app gets the task id back. `callback(from:)`
// reads it; the action parser itself ignores it, so the action shapes stay stable.
//
// Anything else (other scheme, unknown host, missing/blank required value, malformed id) parses to nil
// and is ignored silently: a URL from the outside world must never surface an error dialog.
// Percent-decoding is done by URLComponents; "+" stays a literal plus (RFC 3986), callers encode spaces as %20.
import Foundation

enum KronosURLDue: Equatable {
    case today
    case tomorrow
    /// Validated shape only (`YYYY-MM-DD`); the app resolves it to a day number and drops impossible dates.
    case iso(String)
}

enum KronosURLAction: Equatable {
    case add(title: String, notes: String?, project: String?, due: KronosURLDue?)
    case open(UUID)
    case quickAdd
    case capture(String)
    case impuls
    case complete(UUID)
    case search(String)
    case scope(KronosURLScope)
}

/// The list a `kronos://scope` URL switches to. Named scopes are the fixed sidebar lists; a project is
/// matched by name by the router (the parser has no store).
enum KronosURLScope: Equatable {
    case inbox, today, next7, waiting, someday, all
    case project(String)
}

enum KronosURLParser {
    static let scheme = "kronos"
    /// Caps keep a hostile or buggy caller from pushing megabytes into a title or a Capture box.
    static let maxTitle = 500
    static let maxNotes = 10_000
    static let maxProject = 200
    static let maxCapture = 20_000
    static let maxSearch = 500
    static let maxCallback = 2_000
    /// Schemes an `x-success` URL may never use: local files, script-ish payloads, and Kronos itself
    /// (a callback into `kronos://` could chain into a loop).
    static let blockedCallbackSchemes: Set<String> = ["file", "javascript", "data", "vbscript", "kronos"]

    static func parse(_ url: URL) -> KronosURLAction? {
        guard url.scheme?.lowercased() == scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host?.lowercased() else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }
        switch host {
        case "add":
            guard let title = clean(value("title"), cap: maxTitle, singleLine: true) else { return nil }
            return .add(title: title,
                        notes: clean(value("notes"), cap: maxNotes, singleLine: false),
                        project: clean(value("project"), cap: maxProject, singleLine: true),
                        due: due(value("due")))
        case "open":
            guard let raw = value("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let id = UUID(uuidString: raw) else { return nil }
            return .open(id)
        case "quickadd":
            return .quickAdd
        case "capture":
            guard let text = clean(value("text"), cap: maxCapture, singleLine: false) else { return nil }
            return .capture(text)
        case "impuls":
            return .impuls
        case "complete":
            guard let raw = value("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let id = UUID(uuidString: raw) else { return nil }
            return .complete(id)
        case "search":
            guard let q = clean(value("q") ?? value("query"), cap: maxSearch, singleLine: true) else { return nil }
            return .search(q)
        case "scope":
            if let name = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty {
                return scope(named: name).map(KronosURLAction.scope)
            }
            guard let project = clean(value("project"), cap: maxProject, singleLine: true) else { return nil }
            return .scope(.project(project))
        default:
            return nil
        }
    }

    static func scope(named name: String) -> KronosURLScope? {
        switch name {
        case "inbox": return .inbox
        case "today": return .today
        case "next7", "next-7", "upcoming": return .next7
        case "waiting": return .waiting
        case "someday": return .someday
        case "all": return .all
        default: return nil
        }
    }

    /// The `x-success` URL of a `kronos://` URL, or nil when absent, malformed, too long or using a blocked scheme.
    static func callback(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name.lowercased() == "x-success" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= maxCallback,
              let callback = URL(string: raw), let cs = callback.scheme?.lowercased(),
              cs.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil,
              !blockedCallbackSchemes.contains(cs) else { return nil }
        return callback
    }

    /// `callback` with `id` (and `title` when given) appended to its query, existing items kept.
    static func successURL(callback: URL, id: UUID, title: String?) -> URL {
        guard var comps = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return callback }
        // Percent-encoded by hand: URLComponents leaves "+" alone in a query, and the receiver reads it as a space.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var parts = comps.percentEncodedQuery.map { [$0] } ?? []
        parts.append("id=" + id.uuidString)
        if let title, !title.isEmpty, let enc = title.addingPercentEncoding(withAllowedCharacters: unreserved) {
            parts.append("title=" + enc)
        }
        comps.percentEncodedQuery = parts.joined(separator: "&")
        return comps.url ?? callback
    }

    /// Trimmed, capped, nil when blank. A title is one line: a newline from the caller becomes a space.
    static func clean(_ raw: String?, cap: Int, singleLine: Bool) -> String? {
        guard var s = raw else { return nil }
        if singleLine { s = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > cap { s = String(s.prefix(cap)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return s.isEmpty ? nil : s
    }

    static func due(_ raw: String?) -> KronosURLDue? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if s == "today" { return .today }
        if s == "tomorrow" { return .tomorrow }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return .iso(s)
    }
}
