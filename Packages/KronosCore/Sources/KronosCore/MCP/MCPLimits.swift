#if os(macOS)
// MCP. Size limits a client call must respect. An MCP client is a model (or a script) on this
// Mac, and a runaway one must not be able to write a megabyte title into the task database or
// make one request fan out into hundreds of dispatches.

import Foundation

public enum MCPLimits {
    /// Requests allowed in one JSON-RPC batch array. A larger array is rejected whole.
    public static let maxBatchRequests = 20
    /// Characters (not bytes) in a task or step title.
    public static let maxTitleCharacters = 500
    /// Characters (not bytes) in a task's notes.
    public static let maxNotesCharacters = 20_000
    /// Links attached by one call, and characters in one link.
    public static let maxLinks = 20
    public static let maxLinkCharacters = 2000
    /// Characters in an `externalID`.
    public static let maxExternalIDCharacters = 200
}

extension MCPDispatcher {

    /// The triage field a create_task protected-field name stands for.
    static func triageField(_ name: String) -> TriageFieldKind? {
        switch name {
        case "firstMove": return .firstMove
        case "project": return .project
        case "priority": return .priority
        case "due": return .due
        case "labels": return .labels
        case "depth": return .depth
        case "estimateMinutes": return .estimateMinutes
        case "effort": return .effort
        case "energyKind": return .energyKind
        default: return nil
        }
    }

    // MARK: - Strict parameters

    /// INVALID_PARAMS naming every key the tool does not define, or nil. Runs before decoding so
    /// a misspelt or wrong-tool key (`dueDay` on create_task) can never be silently dropped.
    func unknownKeyError(_ tool: MCPTool, _ arguments: Data) -> MCPToolOutcome? {
        guard let obj = try? JSONSerialization.jsonObject(with: arguments) else {
            return .error(.invalidParams, message: "arguments of \(tool.name) are not valid JSON")
        }
        guard let dict = obj as? [String: Any] else {
            return .error(.invalidParams, message: "arguments of \(tool.name) must be a JSON object")
        }
        let unknown = Set(dict.keys).subtracting(tool.allowedKeys).sorted()
        guard !unknown.isEmpty else { return nil }
        let named = unknown.map { "`\($0)`" }.joined(separator: ", ")
        let known = tool.allowedKeys.sorted().joined(separator: ", ")
        return .error(.invalidParams,
                      message: "unknown parameter\(unknown.count == 1 ? "" : "s") \(named) for \(tool.name); accepted: \(known)",
                      data: ["unknownKeys": unknown])
    }

    /// Decodes a tool's arguments. A failure names the offending field through its coding path.
    func decodeParams<T: Decodable>(_ type: T.Type, _ arguments: Data, tool: String) throws -> T {
        do {
            return try MCPJSON.decoder.decode(type, from: arguments)
        } catch let e as DecodingError {
            throw MCPToolOutcome.decodeFailure(e, tool: tool)
        } catch {
            throw MCPToolOutcome.error(.invalidParams, message: "could not decode \(tool) arguments")
        }
    }

    // MARK: - Value checks

    /// A yyyy-MM-dd string as a day number, or an error naming the field.
    func parseDay(_ raw: String, field: String) -> (day: Int?, error: MCPToolOutcome?) {
        guard let d = Day.parseISO(raw) else {
            return (nil, .error(.invalidParams, message: "\(field) is not a valid date (yyyy-MM-dd): \(raw)",
                                data: ["field": field]))
        }
        return (d, nil)
    }

    /// The first bad link, as a tool error, or nil. Only http and https with a host are accepted.
    func linkError(_ links: [String]?) -> MCPToolOutcome? {
        guard let links else { return nil }
        if links.count > MCPLimits.maxLinks {
            return .error(.invalidParams, message: "links has \(links.count) entries; the limit is \(MCPLimits.maxLinks)",
                          data: ["field": "links"])
        }
        for raw in links {
            let ok = raw.count <= MCPLimits.maxLinkCharacters
                && URL(string: raw).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && ($0.host?.isEmpty == false) } == true
            if !ok {
                return .error(.invalidParams, message: "links entry is not an http(s) URL of at most \(MCPLimits.maxLinkCharacters) characters: \(raw.prefix(80))",
                              data: ["field": "links"])
            }
        }
        return nil
    }

    /// Where a task written by the current caller comes from: `agent:<name>` through the bridge,
    /// `mcp` for a client that sent no name.
    var sourceTag: String {
        if let me = identity { return me.actor }
        guard let name = clientName else { return "mcp" }
        return "agent:\(name)"
    }

    /// An ISO-8601 time with or without fractional seconds, or a plain yyyy-MM-dd day (local midnight).
    static func parseTimestamp(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: raw) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: raw) { return d }
        return Day.parseISO(raw).map { Day.date($0) }
    }

    /// The `reviewRaw` a wire name stands for.
    static func reviewRaw(named name: String) -> Int? {
        switch name {
        case "pending": return ReviewState.pending
        case "approved": return ReviewState.approved
        case "rejected": return ReviewState.rejected
        case "awaitingCheck": return ReviewState.awaitingCheck
        default: return nil
        }
    }

    /// A client name made safe to store and show: letters, digits, space, dot, dash, underscore,
    /// at most 40 characters. Anything else becomes a dash; nothing left means no name.
    static func sanitizedClientName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let mapped = String(String.UnicodeScalarView(raw.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: " -")).prefix(40)
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    /// The first violated size limit as a tool error naming the field, or nil when every given
    /// value fits. Called before any store write so a rejected call changes nothing.
    func lengthError(title: String? = nil, notes: String? = nil) -> MCPToolOutcome? {
        if let title, title.count > MCPLimits.maxTitleCharacters {
            return .error(.invalidParams,
                          message: "title is \(title.count) characters; the limit is \(MCPLimits.maxTitleCharacters)",
                          data: ["field": "title", "limit": MCPLimits.maxTitleCharacters])
        }
        if let notes, notes.count > MCPLimits.maxNotesCharacters {
            return .error(.invalidParams,
                          message: "notes is \(notes.count) characters; the limit is \(MCPLimits.maxNotesCharacters)",
                          data: ["field": "notes", "limit": MCPLimits.maxNotesCharacters])
        }
        return nil
    }
}
#endif
