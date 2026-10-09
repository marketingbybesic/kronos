// Limits that keep one runaway agent from flooding the person: a token bucket per agent for
// calls per minute, a daily cap on created tasks, and a ceiling on unreviewed proposals.

import Foundation

/// Token bucket per agent slug. Capacity = calls per minute, refilled evenly.
@MainActor
public final class AgentLimiter {
    private struct Bucket { var tokens: Double; var at: Date }
    private var buckets: [String: Bucket] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = { Date() }) { self.now = now }

    /// Takes one call from the agent's bucket. `retryAfter` is whole seconds until one is free.
    public func consume(slug: String, perMinute: Int) -> (allowed: Bool, retryAfter: Int) {
        let capacity = Double(max(perMinute, 1))
        let t = now()
        var b = buckets[slug] ?? Bucket(tokens: capacity, at: t)
        let elapsed = max(0, t.timeIntervalSince(b.at))
        b.tokens = min(capacity, b.tokens + elapsed * capacity / 60)
        b.at = t
        if b.tokens >= 1 {
            b.tokens -= 1
            buckets[slug] = b
            return (true, 0)
        }
        buckets[slug] = b
        let missing = 1 - b.tokens
        return (false, Int((missing * 60 / capacity).rounded(.up)))
    }

    /// Calls taken from the bucket so far this window, without consuming one (Settings display).
    public func used(slug: String, perMinute: Int) -> Int {
        guard let b = buckets[slug] else { return 0 }
        let capacity = Double(max(perMinute, 1))
        let elapsed = max(0, now().timeIntervalSince(b.at))
        let refilled = min(capacity, b.tokens + elapsed * capacity / 60)
        return max(0, Int((capacity - refilled).rounded()))
    }

    public func reset(slug: String) { buckets[slug] = nil }
}

/// Wire codes and messages of the three refusals, shared by dispatcher and tests.
public enum MCPLimitCodes {
    public static func reviewBacklogMessage(pending: Int, max: Int) -> String {
        "Alex has \(pending) unreviewed proposals (limit \(max)); wait for events before proposing more"
    }
}
