#if os(macOS)
// events_poll with waitSeconds: the call is held until an event exists or the time is up. The
// wait is an async suspension on the main actor, never a blocked thread, so the app stays
// responsive while an agent waits (up to 55 s; the bridge allows a tool call 300 s).

import Foundation

extension MCPDispatcher {

    public static let maxWaitSeconds = 55
    /// How often a held poll looks again. Short enough that an person action reaches the agent in about a second.
    public static let longPollInterval: TimeInterval = 1.0

    /// Seconds to hold when `body` is one events_poll request asking to wait, else nil.
    func longPollSeconds(in body: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              obj["method"] as? String == "tools/call",
              let params = obj["params"] as? [String: Any], params["name"] as? String == "events_poll",
              let args = params["arguments"] as? [String: Any],
              let wait = (args["waitSeconds"] as? NSNumber)?.intValue, wait > 0 else { return nil }
        return min(wait, Self.maxWaitSeconds)
    }

    /// Like `handleBody`, but holds an events_poll that asks to wait. `sleep` and `now` are
    /// injectable so the schedule can be tested without real time.
    public func handleBodyHolding(_ body: Data, client: String? = nil, agent: AgentIdentity? = nil,
                                  sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                                  now: @escaping () -> Date = { Date() }) async -> Reply {
        guard let wait = longPollSeconds(in: body) else { return handleBody(body, client: client, agent: agent) }
        let deadline = now().addingTimeInterval(TimeInterval(wait))
        var counted = false
        while true {
            // The call is counted once against the rate limit, not once per look.
            skipRateLimit = counted
            let reply = handleBody(body, client: client, agent: agent)
            skipRateLimit = false
            counted = true
            if Self.hasEvents(reply) || Self.isToolError(reply) { return reply }
            let remaining = deadline.timeIntervalSince(now())
            if remaining <= 0 { return reply }
            await sleep(min(Self.longPollInterval, remaining))
        }
    }

    private static func structured(_ reply: Reply) -> [String: Any]? {
        guard let data = reply.body,
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = top["result"] as? [String: Any] else { return nil }
        return result
    }

    static func hasEvents(_ reply: Reply) -> Bool {
        ((structured(reply)?["structuredContent"] as? [String: Any])?["events"] as? [Any])?.isEmpty == false
    }

    static func isToolError(_ reply: Reply) -> Bool {
        guard let r = structured(reply) else { return true }   // a protocol error ends the wait too
        return (r["isError"] as? Bool) == true
    }
}
#endif
