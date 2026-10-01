// Kronos/App/URLScheme.swift
// Pure parser for the `kronos://` URL scheme. Foundation only, on purpose: scripts/urlscheme-selftest.swift
// compiles THIS file with a hand-written table, so the shipped parser is the one proven.
//
//   kronos://add?title=…&notes=…&project=…&due=today|tomorrow|YYYY-MM-DD
//   kronos://open?id=<uuid>
//   kronos://quickadd
//   kronos://capture?text=…
//   kronos://impuls
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
}

enum KronosURLParser {
    static let scheme = "kronos"
    /// Caps keep a hostile or buggy caller from pushing megabytes into a title or a Capture box.
    static let maxTitle = 500
    static let maxNotes = 10_000
    static let maxProject = 200
    static let maxCapture = 20_000

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
        default:
            return nil
        }
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
