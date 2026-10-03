// Small pure decisions the AI wiring and the screens share, kept in Core so a hand table can
// test them without an app.

import Foundation

/// Which configured models answer fast enough for the one AI call that has a 4 s window
/// (the Impuls mentor line). Measured: a model that takes 13 to 17 s per call never lands inside
/// the window, so asking it only costs tokens and egress.
public enum FastModel {
    /// Lower-case fragments of model ids that answer inside the window: the small hosted models and
    /// the on-device model. Anything else (the large hosted models) is treated as slow.
    static let fastFragments = ["astra", "haiku", "flash", "qwen3.8-27b", "apple-on-device"]

    public static func isFast(modelID: String) -> Bool {
        let id = modelID.lowercased()
        return fastFragments.contains { id.contains($0) }
    }
}

/// When a screen may ask a model at all.
public enum AICallPolicy {
    /// - Parameters:
    ///   - switchOn: the visible "AI suggestions" switch of the screen.
    ///   - hasRouter: an AI router is configured (nil means AI is off in Settings).
    ///   - mode: the router's privacy mode.
    public static func mayAsk(switchOn: Bool, hasRouter: Bool, mode: AIMode?) -> Bool {
        guard switchOn, hasRouter else { return false }
        return mode != .off
    }
}

/// The settings a built router depends on. The wiring rebuilds the router only when this value
/// changes, so an unrelated preference (window size, a sound) never throws the router away.
public struct RouterConfigSignature: Equatable, Sendable {
    public let mode: AIMode
    public let provider: String
    public let baseURL: String
    public let modelID: String
    public let rules: [HouseRule]

    public init(mode: AIMode, provider: String, baseURL: String, modelID: String, rules: [HouseRule]) {
        self.mode = mode
        self.provider = provider
        self.baseURL = baseURL
        self.modelID = modelID
        self.rules = rules.filter(\.isActive)
    }
}

/// Egress limits for lists of task titles that leave the Mac inside a prompt.
public enum EgressLimits {
    /// Open task titles sent with a Capture request (used only to mark duplicates).
    public static let captureTitleCount = 50
    /// Longest title sent, in characters.
    public static let titleLength = 80

    /// The newest `limit` titles, each cut to `titleLength` and redacted.
    public static func cappedTitles(_ titles: [String], limit: Int = captureTitleCount) -> [String] {
        titles.prefix(limit).map { PrivacyRedactor.redact(String($0.prefix(titleLength))) }
    }
}

/// The mentor line limit the prompt promises and the lint enforces: one number for both.
public enum MentorLineLimits {
    public static let maxCharacters = 90
}

/// A mentor line must read like a peer, not a coach. A line that fails is dropped exactly like a
/// timeout: no retry, no error. Phrase lists cover English and Croatian.
public enum MentorLineCheck {
    private static let bannedSubstrings: [String] = [
        // English
        "you've got this", "you can do it", "come on", "let's go", "crush it", "smash it",
        "just do it", "you did", "you should", "as promised", "one more push", "let's finally",
        "before it's too late", "while you still can", "quick!", "now or never",
        "still not done", "don't forget", "you've been avoiding",
        // Croatian
        "moraš", "možeš ti to", "hajde", "samo naprijed", "da se vratimo", "ne zaboravi",
        "još nije gotovo", "već dugo", "izbjegavaš", "do sad si trebao", "trebao bi", "trebala bi",
        "požuri", "sad ili nikad",
    ]

    public static func pass(_ line: String, unlessIdenticalTo generic: String) -> Bool {
        guard line != generic else { return false }
        guard line.count <= MentorLineLimits.maxCharacters else { return false }
        guard !line.contains("!"), !line.contains("?") else { return false }
        let dotCount = line.filter { $0 == "." }.count
        guard dotCount <= 1 else { return false }
        guard !line.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.properties.isEmojiPresentation }) else { return false }
        let lower = line.lowercased()
        return !bannedSubstrings.contains { lower.contains($0) }
    }
}

/// Debounce for the Impuls mentor line: a card asks the model once, however often the store
/// ticks while the card is on screen.
public struct RefinementGate: Sendable {
    private var requested: UUID?

    public init() {}

    /// True the first time `taskID` is asked about; false for every later ask until `reset()`.
    public mutating func shouldRequest(for taskID: UUID) -> Bool {
        guard requested != taskID else { return false }
        requested = taskID
        return true
    }

    /// A new card (another pick, energy change) may ask again.
    public mutating func reset() { requested = nil }
}
