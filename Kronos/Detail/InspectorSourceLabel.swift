// Who wrote a task: the line "From Codex" under the inspector title for a task an agent
// created. Pure Foundation so a table test compiles this exact file.
// `source` is `agent:<name>` for a task written through the MCP bridge by a named client,
// `mcp` for a client that sent no name; every other value (import tags, the app itself) is not
// an agent. A task carrying an `agentID` with no readable source is still from an agent.
import Foundation

enum InspectorSourceLabel {
    enum Kind: Equatable {
        case none
        case generic
        case agent(String)
    }

    private static let agentPrefix = "agent:"

    /// `resolveDisplayName` looks up the agent's own stored display name (Settings > Agents) by
    /// slug; when it has one, that is shown verbatim — never re-guessed. Every existing caller
    /// that passes none keeps the exact prior behaviour (the capitalised guess below).
    static func kind(source: String?, hasAgentID: Bool, resolveDisplayName: (String) -> String? = { _ in nil }) -> Kind {
        let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasPrefix(agentPrefix) {
            let slug = raw.dropFirst(agentPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if slug.isEmpty { return .generic }
            return .agent(resolveDisplayName(slug) ?? displayName(slug))
        }
        if raw == "mcp" { return .generic }
        return raw.isEmpty && hasAgentID ? .generic : .none
    }

    /// A client name as it reads in a sentence when no stored display name is on record: an
    /// all-lowercase name gets its first letter capitalised ("codex" -> "Codex"); a name with
    /// any capital is the client's own spelling.
    static func displayName(_ name: String) -> String {
        guard let first = name.first, name == name.lowercased() else { return name }
        return first.uppercased() + name.dropFirst()
    }
}
