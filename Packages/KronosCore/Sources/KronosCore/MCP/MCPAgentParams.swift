#if os(macOS)
// Parameters of the agent-loop tools, and the extra keys the older tools gained for it. The
// extras are decoded from the same arguments as the original structs, so those stay untouched.

import Foundation

extension MCPParams {

    /// `create_task` keys added for agents.
    struct CreateExtras: Decodable {
        var context: AgentContext?
        var assignee: String?
    }

    /// `list_tasks` keys added for agents.
    struct ListExtras: Decodable {
        var updatedSince: String?
        var completedSince: String?
        var owner: String?
        var review: String?
    }

    /// `complete_task` key added for agents.
    struct CompleteExtras: Decodable {
        struct Result: Decodable {
            var note: String?
            var links: [AgentContext.Link]?
        }
        var result: Result?
    }

    struct ProposedTask: Decodable {
        var title: String
        var due: String?
        var plannedDay: String?
        var priority: MCPPriority?
        var project: String?
        var subtasks: [String]?
        var context: AgentContext?
    }

    struct ProposeTasks: Decodable {
        var title: String
        var context: AgentContext?
        var tasks: [ProposedTask]
    }

    struct ProposeUpdate: Decodable {
        var id: UUID
        var patch: [String: AgentJSON]
        var why: String?
    }

    struct CommentTask: Decodable {
        var id: UUID
        var text: String
    }

    struct EventsPoll: Decodable {
        var since: String?
        var kinds: [String]?
        var waitSeconds: Int?
        var limit: Int?
        var format: String?
    }

    struct EventsAck: Decodable {
        var upTo: String
    }

    struct Next: Decodable {
        enum Energy: String, Decodable { case low, mid, high }
        var energy: Energy?
    }
}
#endif
