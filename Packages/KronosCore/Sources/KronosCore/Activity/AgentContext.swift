// What an agent attaches to a task so the person can decide in one glance, and what comes back
// when the task closes. Both live as JSON strings on the task (`contextJSON`, `resultJSON`) so
// the person's own notes are never touched.

import Foundation

/// A loose JSON value, for patches and event payloads.
public enum AgentJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSON])
    case object([String: AgentJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AgentJSON].self) { self = .array(v) }
        else if let v = try? c.decode([String: AgentJSON].self) { self = .object(v) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var int: Int? { if case .number(let n) = self { return Int(n) } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var object: [String: AgentJSON]? { if case .object(let o) = self { return o } else { return nil } }
    public var array: [AgentJSON]? { if case .array(let a) = self { return a } else { return nil } }

    /// A JSONSerialization-shaped value (dictionary, array, string, number, bool, NSNull).
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v == v.rounded() && abs(v) < 1e15 ? Int(v) as Any : v
        case .string(let v): return v
        case .array(let v): return v.map(\.any)
        case .object(let v): return v.mapValues(\.any)
        }
    }

    /// From a JSONSerialization-shaped value; nil for a type JSON cannot hold.
    public init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.compactMap(AgentJSON.init(any:)))
        case let o as [String: Any]: self = .object(o.compactMapValues(AgentJSON.init(any:)))
        default: return nil
        }
    }

    public static func encoded(_ object: [String: AgentJSON]) -> String {
        guard let data = try? AgentCoding.encoder.encode(AgentJSON.object(object)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ raw: String) -> [String: AgentJSON]? {
        guard !raw.isEmpty, let v = try? AgentCoding.decoder.decode(AgentJSON.self, from: Data(raw.utf8)) else { return nil }
        return v.object
    }
}

/// One JSON configuration for everything this folder stores: ISO-8601 dates, sorted keys.
enum AgentCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// `KTask.contextJSON`. Everything optional so an old or partial value still decodes.
public struct AgentContext: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var kind: String?
        public var ref: String?
        public var title: String?
        public init(kind: String? = nil, ref: String? = nil, title: String? = nil) {
            self.kind = kind; self.ref = ref; self.title = title
        }
    }
    public struct Link: Codable, Equatable, Sendable {
        public var url: String
        public var title: String?
        public init(url: String, title: String? = nil) { self.url = url; self.title = title }
    }
    /// A change an agent proposes to a task it does not own. The target stays untouched until approved.
    public struct Update: Codable, Equatable, Sendable {
        public var targetID: UUID
        public var patch: [String: AgentJSON]
        public var why: String?
        public init(targetID: UUID, patch: [String: AgentJSON], why: String? = nil) {
            self.targetID = targetID; self.patch = patch; self.why = why
        }
    }
    public struct Comment: Codable, Equatable, Sendable {
        public var at: Date
        public var by: String
        public var text: String
        public init(at: Date, by: String, text: String) { self.at = at; self.by = by; self.text = text }
    }

    public static let maxWhy = 300
    public static let maxExpectedOutcome = 200
    public static let maxLinks = 10
    public static let maxSession = 100
    public static let maxComments = 20
    public static let sourceKinds: Set<String> = ["email", "url", "chat", "file", "repo", "meeting", "calendar", "other"]

    /// "task" (default) or "update".
    public var kind: String?
    public var why: String?
    public var source: Source?
    public var links: [Link]?
    public var expectedOutcome: String?
    public var confidence: Double?
    public var session: String?
    /// Tasks proposed together share one proposal id and title: one review card.
    public var proposalID: UUID?
    public var proposalTitle: String?
    public var update: Update?
    public var comments: [Comment]?

    public init() {}

    public var isUpdate: Bool { kind == "update" && update != nil }

    /// The first problem with a caller-supplied context, or nil.
    public func validationProblem() -> String? {
        if let why, why.count > Self.maxWhy { return "context.why is \(why.count) characters; the limit is \(Self.maxWhy)" }
        if let e = expectedOutcome, e.count > Self.maxExpectedOutcome {
            return "context.expectedOutcome is \(e.count) characters; the limit is \(Self.maxExpectedOutcome)"
        }
        if let links, links.count > Self.maxLinks { return "context.links has \(links.count) entries; the limit is \(Self.maxLinks)" }
        for l in links ?? [] {
            let ok = l.url.count <= 2000 && URL(string: l.url).map {
                ["http", "https"].contains($0.scheme?.lowercased() ?? "") && ($0.host?.isEmpty == false)
            } == true
            if !ok { return "context.links entry is not an http(s) URL: \(l.url.prefix(80))" }
        }
        if let c = confidence, !(0...1).contains(c) { return "context.confidence must be between 0 and 1" }
        if let s = session, s.count > Self.maxSession { return "context.session is longer than \(Self.maxSession) characters" }
        if let k = source?.kind, !Self.sourceKinds.contains(k) {
            return "context.source.kind must be one of \(Self.sourceKinds.sorted().joined(separator: ", "))"
        }
        return nil
    }

    public static func decode(_ raw: String?) -> AgentContext? {
        guard let raw, !raw.isEmpty else { return nil }
        return try? AgentCoding.decoder.decode(AgentContext.self, from: Data(raw.utf8))
    }

    public func encoded() -> String {
        guard let data = try? AgentCoding.encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The comment line added to a task, newest last, oldest dropped past the cap.
    public mutating func append(comment: Comment) {
        var all = comments ?? []
        all.append(comment)
        if all.count > Self.maxComments { all.removeFirst(all.count - Self.maxComments) }
        comments = all
    }
}

/// `KTask.resultJSON`: what the agent hears when the task closes or a proposal is decided.
public struct AgentTaskResult: Codable, Equatable, Sendable {
    /// done, canceled, rejected or deferred.
    public var outcome: String?
    /// "me" or "agent:<slug>".
    public var by: String?
    public var note: String?
    public var links: [AgentContext.Link]?
    /// approve, reject, edit or merge, for a proposal.
    public var decision: String?
    public var editedFields: [String]?
    public var reason: String?
    public var completedAt: Date?
    public var openSubtasksLeft: Int?
    /// The open task a proposal was merged into (decision "merge").
    public var mergedInto: UUID?
    /// The person's verdict on what the agent did or proposed: "accepted" or "rejected". Set by
    /// the person's review actions, or (only when the person granted this agent the `done.trusted`
    /// scope) by `complete_task` itself on a task handed to it, with `decision == "auto"`. No
    /// other MCP tool, and no agent lacking that person-granted scope, can set it.
    public var verdict: String?
    /// What the person said with the verdict (optional).
    public var verdictComment: String?
    public var verdictAt: Date?

    public init() {}

    public static func decode(_ raw: String?) -> AgentTaskResult? {
        guard let raw, !raw.isEmpty else { return nil }
        return try? AgentCoding.decoder.decode(AgentTaskResult.self, from: Data(raw.utf8))
    }

    public func encoded() -> String {
        guard let data = try? AgentCoding.encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
