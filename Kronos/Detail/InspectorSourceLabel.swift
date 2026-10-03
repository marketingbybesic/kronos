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

    static func kind(source: String?, hasAgentID: Bool) -> Kind {
        let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasPrefix(agentPrefix) {
            let name = raw.dropFirst(agentPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? .generic : .agent(displayName(name))
        }
        if raw == "mcp" { return .generic }
        return raw.isEmpty && hasAgentID ? .generic : .none
    }

    /// A client name as it reads in a sentence: an all-lowercase name gets its first letter
    /// capitalised ("codex" -> "Codex"); a name with any capital is the client's own spelling.
    static func displayName(_ name: String) -> String {
        guard let first = name.first, name == name.lowercased() else { return name }
        return first.uppercased() + name.dropFirst()
    }
}
