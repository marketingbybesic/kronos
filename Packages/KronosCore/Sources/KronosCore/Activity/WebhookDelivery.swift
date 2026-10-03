// How an agent that is not connected hears events: an HTTPS webhook (HMAC-signed), an ntfy
// message on its own topic, or a local command. The target is set only from the Kronos UI,
// never over MCP, so an agent cannot point Alex's data at a URL it chose. This file is the pure
// part (parsing, signing, retry schedule, one delivery pass); the transport lives in the app.

import Foundation
import CryptoKit

/// Where one agent's events go, stored in `KAgent.webhookURL` as one string:
/// `https://host/path` (webhook), `ntfy+https://host/topic` (ntfy), `exec:["ssh","relay","cmd"]` (argv).
public enum DeliveryTarget: Equatable, Sendable {
    case webhook(URL)
    case ntfy(URL)
    case command([String])

    public static func parse(_ raw: String?) -> DeliveryTarget? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("exec:") {
            let json = String(raw.dropFirst("exec:".count))
            guard let argv = try? JSONDecoder().decode([String].self, from: Data(json.utf8)),
                  let first = argv.first, !first.isEmpty, argv.allSatisfy({ !$0.contains("\0") }) else { return nil }
            return .command(argv)
        }
        if raw.hasPrefix("ntfy+") {
            guard let url = secureURL(String(raw.dropFirst("ntfy+".count))) else { return nil }
            return .ntfy(url)
        }
        guard let url = secureURL(raw) else { return nil }
        return .webhook(url)
    }

    /// https with a host; plain http only for loopback (a local receiver).
    static func secureURL(_ s: String) -> URL? {
        guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return nil }
        if u.scheme?.lowercased() == "https" { return u }
        if u.scheme?.lowercased() == "http", host == "127.0.0.1" || host == "localhost" { return u }
        return nil
    }

    public var stored: String {
        switch self {
        case .webhook(let u): return u.absoluteString
        case .ntfy(let u): return "ntfy+" + u.absoluteString
        case .command(let argv):
            let data = (try? JSONEncoder().encode(argv)) ?? Data("[]".utf8)
            return "exec:" + String(decoding: data, as: UTF8.self)
        }
    }
}

public enum WebhookSigner {
    /// `t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>`.
    public static func header(secret: String, timestamp: Int, body: Data) -> String {
        var message = Data("\(timestamp).".utf8)
        message.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        return "t=\(timestamp),v1=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Retry schedule: after the first failure wait 1 min, then 5 min, 30 min, 2 h, and keep trying
/// every 2 h until the event is 24 h old; then it is dead.
public enum WebhookRetry {
    public static let schedule: [TimeInterval] = [60, 300, 1800, 7200]
    public static let deadAfter: TimeInterval = 86_400

    public enum Decision: Equatable, Sendable {
        case deliverNow
        case wait(until: Date)
        case dead
    }

    /// `attempts` = failed tries so far; `lastAttempt` = when the last one happened.
    public static func decide(eventAt: Date, attempts: Int, lastAttempt: Date?, now: Date) -> Decision {
        if now.timeIntervalSince(eventAt) >= deadAfter { return .dead }
        guard attempts > 0, let last = lastAttempt else { return .deliverNow }
        let gap = schedule[min(attempts - 1, schedule.count - 1)]
        let due = last.addingTimeInterval(gap)
        return now >= due ? .deliverNow : .wait(until: due)
    }
}

/// What the transport is asked to send.
public struct DeliveryMessage: Equatable, Sendable {
    public var seq: Int
    public var kind: String
    public var title: String
    public var body: Data
    /// The person's one-line note, for a plain-text channel such as ntfy.
    public var note: String?
    public init(seq: Int, kind: String, title: String, body: Data, note: String? = nil) {
        self.seq = seq; self.kind = kind; self.title = title; self.body = body; self.note = note
    }
}

public protocol DeliveryTransport: Sendable {
    /// True when the receiver accepted the message.
    func send(_ message: DeliveryMessage, to target: DeliveryTarget, secret: String?) async -> Bool
}

/// One delivery pass over the events waiting for a webhook.
@MainActor
public final class WebhookDispatcher {
    private let hub: AgentHub
    private let transport: DeliveryTransport
    private let secrets: (String) -> String?
    private var attempts: [UUID: (count: Int, last: Date)] = [:]

    public init(hub: AgentHub, transport: DeliveryTransport, secrets: @escaping (String) -> String? = { _ in nil }) {
        self.hub = hub
        self.transport = transport
        self.secrets = secrets
    }

    /// The JSON an agent receives: only its own task, the event, the result and a memory block.
    public static func payload(for row: KActivity, store: any TaskStoring) -> Data {
        let task = row.taskID.flatMap { store.taskIncludingDeleted($0) }
        let event = DigestEvent(row: row, title: task?.title)
        var obj: [String: AgentJSON] = [
            "seq": .number(Double(row.seq)), "kind": .string(row.verb), "actor": .string(row.actor),
            "at": .string(ISO8601DateFormatter().string(from: row.at)), "title": .string(event.title),
        ]
        if let id = row.taskID { obj["taskID"] = .string(id.uuidString) }
        if let n = event.note { obj["note"] = .string(n) }
        if let r = event.reason { obj["reason"] = .string(r) }
        if let d = event.decision { obj["decision"] = .string(d) }
        obj["memory"] = .object(["markdown": .string(EventDigest.memory(for: event).markdown),
                                 "json": .object(EventDigest.memory(for: event).json)])
        return (try? AgentCoding.encoder.encode(AgentJSON.object(obj))) ?? Data("{}".utf8)
    }

    /// Delivers what is due. Returns (delivered, retrying, dead) counts of this pass.
    @discardableResult
    public func run(store: any TaskStoring) async -> (delivered: Int, retrying: Int, dead: Int) {
        var delivered = 0, retrying = 0, dead = 0
        let pending = hub.rows().filter { $0.webhookStateRaw == 1 }
        for row in pending {
            guard let agentID = row.agentID, let agent = hub.agent(id: agentID),
                  let target = DeliveryTarget.parse(agent.webhookURL) else {
                row.webhookStateRaw = 0   // delivery was switched off meanwhile
                continue
            }
            let a = attempts[row.id]
            switch WebhookRetry.decide(eventAt: row.at, attempts: row.webhookAttempts, lastAttempt: a?.last, now: hub.now()) {
            case .dead:
                row.webhookStateRaw = 3
                dead += 1
            case .wait:
                retrying += 1
            case .deliverNow:
                let event = DigestEvent(row: row, title: row.taskID.flatMap { store.taskIncludingDeleted($0)?.title })
                let msg = DeliveryMessage(seq: row.seq, kind: row.verb, title: event.title,
                                          body: Self.payload(for: row, store: store), note: event.note)
                let ok = await transport.send(msg, to: target, secret: agent.webhookSecretName.flatMap(secrets))
                if ok {
                    row.webhookStateRaw = 2
                    delivered += 1
                } else {
                    row.webhookAttempts += 1
                    attempts[row.id] = (row.webhookAttempts, hub.now())
                    retrying += 1
                }
            }
        }
        hub.save()
        return (delivered, retrying, dead)
    }
}
