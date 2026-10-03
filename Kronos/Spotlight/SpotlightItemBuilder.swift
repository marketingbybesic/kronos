// Kronos/Spotlight/SpotlightItemBuilder.swift
//
// Pure item-shaping logic, Foundation-only (no CoreSpotlight, no KronosCore) so
// `scripts/verify-intents.mjs` can compile and exercise it with a bare `swiftc` fixture.
// `SpotlightIndexer.swift` turns these plain structs into real `CSSearchableItem`s.
//
// Never indexes notes text or anything that looks like a secret: only title,
// first move, project name and a deadline string ever go into `SearchableFacts`, and
// `looksLikeSecret` is a last line of defense against a title/first-move that happens to
// contain something credential-shaped (a pasted API key used as a task title, for example).

import Foundation

/// One indexable fact set — a task or a project — with everything `SpotlightIndexer` needs
/// to build (or remove) a searchable item, and nothing else.
struct SearchableFacts: Equatable, Sendable {
    enum Kind: String, Sendable { case task, project }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let firstMove: String?
    let deadlineText: String?
    /// Extra words Spotlight matches on (the project name, label names, "Kronos").
    let keywords: [String]
    /// Where a click on the result goes outside the app (`kronos://open?id=`); tasks only.
    let contentURL: String?

    init(id: String, kind: Kind, title: String, subtitle: String? = nil,
                firstMove: String? = nil, deadlineText: String? = nil,
                keywords: [String] = [], contentURL: String? = nil) {
        self.keywords = keywords
        self.contentURL = contentURL
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.firstMove = firstMove
        self.deadlineText = deadlineText
    }

    /// The Spotlight domain identifier this item's unique id is scoped under, so a task id
    /// and a project id can never collide even if UUIDs somehow matched.
    var domainIdentifier: String { "com.besic.kronos.\(kind.rawValue)" }

    /// A hash of everything that goes into the index entry (FNV-1a over a fixed field order), so a
    /// pass can tell a changed item from an untouched one without keeping the facts around.
    var contentHash: UInt64 {
        let fields: [String] = [id, kind.rawValue, title, subtitle ?? "", firstMove ?? "",
                                deadlineText ?? "", keywords.joined(separator: "\u{1E}"), contentURL ?? ""]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in fields.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// What one indexing pass has to do, given what the last pass indexed.
enum SpotlightDiff {
    struct Plan: Equatable {
        /// New or changed items only.
        var index: [SearchableFacts]
        /// Ids that were indexed before and are gone now.
        var delete: [String]
        /// The hashes to remember once the pass succeeded.
        var hashes: [String: UInt64]
    }

    static func plan(previous: [String: UInt64], current: [SearchableFacts]) -> Plan {
        var hashes: [String: UInt64] = [:]
        var index: [SearchableFacts] = []
        for facts in current {
            let h = facts.contentHash
            hashes[facts.id] = h
            if previous[facts.id] != h { index.append(facts) }
        }
        let delete = previous.keys.filter { hashes[$0] == nil }.sorted()
        return Plan(index: index, delete: delete, hashes: hashes)
    }
}

/// Reads the id back from what a Spotlight click hands the app (`task.<uuid>` / `project.<uuid>`).
enum SpotlightIdentifier {
    enum Target: Equatable { case task(UUID), project(UUID) }

    static func parse(_ raw: String) -> Target? {
        if raw.hasPrefix("task."), let id = UUID(uuidString: String(raw.dropFirst("task.".count))) { return .task(id) }
        if raw.hasPrefix("project."), let id = UUID(uuidString: String(raw.dropFirst("project.".count))) { return .project(id) }
        return nil
    }
}

enum SpotlightSafety {
    /// Never index a title/first-move/subtitle that looks like a credential someone pasted
    /// into a task by mistake — long unbroken alphanumeric runs (API-key shaped), or a
    /// string containing an obvious secret-bearing prefix. Conservative on purpose: a false
    /// positive just means one task is not searchable by title, which is a small loss next
    /// to leaking a key into the system-wide Spotlight index.
    static func looksLikeSecret(_ s: String) -> Bool {
        let lower = s.lowercased()
        let prefixes = ["sk-", "ghp_", "xox", "bearer ", "-----begin"]
        if prefixes.contains(where: { lower.contains($0) }) { return true }
        // A single token >= 24 chars of mixed letters+digits with no spaces (an API key
        // shape); plain English/Croatian words this long practically never occur.
        for token in s.split(separator: " ") where token.count >= 24 {
            let hasLetter = token.contains { $0.isLetter }
            let hasDigit = token.contains { $0.isNumber }
            if hasLetter && hasDigit { return true }
        }
        return false
    }

    /// Facts safe to hand to the real index, or nil to skip indexing this item entirely
    /// (a whole-item skip, never a partial redaction that could still leak part of a key).
    static func sanitize(_ facts: SearchableFacts) -> SearchableFacts? {
        let strings = [facts.title, facts.subtitle, facts.firstMove].compactMap { $0 }
        guard !strings.contains(where: looksLikeSecret) else { return nil }
        return facts
    }
}
