import Foundation

/// Which projects a typed prefix finds, best first: the one ranking behind every project picker
/// (the inspector's Project field, the `P` key, the palette's "Move to", the entry field's `#`).
///
/// The match tiers are the entry field's own (`EntryMatchTier`: exact > prefix > word-prefix >
/// contains > fuzzy), so "#koy" and a picker typed "koy" agree. Recency only ever breaks a tie
/// inside one tier, except for an empty query, where the whole list is recents first: the projects
/// the person filed something into lately, most recent first, then the rest in manual order.
public enum ProjectRanking {

    /// What the ranking needs to know about a project; plain values so it is testable and
    /// Sendable. `KProject` converts through `init(_:)`.
    public struct Candidate: Hashable, Sendable {
        public var id: UUID
        public var name: String
        /// The area the project sits in, shown quietly beside the name by pickers.
        public var areaName: String?

        public init(id: UUID, name: String, areaName: String? = nil) {
            self.id = id
            self.name = name
            self.areaName = areaName
        }

        public init(_ project: KProject) {
            self.init(id: project.id, name: project.name, areaName: project.area?.name)
        }
    }

    /// `projects` in manual order (the order `TaskStore.allProjects()` returns); `recents` maps a
    /// project id to when it was last used. Projects that do not match `query` are dropped.
    public static func rank(query: String, projects: [Candidate], recents: [UUID: Date]) -> [Candidate] {
        let key = EntryMatcher.normalize(query)
        if key.isEmpty {
            return ordered(projects.enumerated().map { (index: $0.offset, tier: EntryMatchTier.exact, candidate: $0.element) },
                           recents: recents, byTier: false)
        }
        var hits: [(index: Int, tier: EntryMatchTier, candidate: Candidate)] = []
        for (index, candidate) in projects.enumerated() where !candidate.name.isEmpty {
            if let tier = EntryMatcher.tier(key: key, candidate: EntryMatcher.normalize(candidate.name)) {
                hits.append((index, tier, candidate))
            }
        }
        return ordered(hits, recents: recents, byTier: true)
    }

    /// Convenience for the store's own rows.
    public static func rank(query: String, projects: [KProject], recents: [UUID: Date]) -> [Candidate] {
        rank(query: query, projects: projects.map(Candidate.init), recents: recents)
    }

    private static func ordered(_ hits: [(index: Int, tier: EntryMatchTier, candidate: Candidate)],
                                recents: [UUID: Date], byTier: Bool) -> [Candidate] {
        hits.sorted { a, b in
            if byTier, a.tier != b.tier { return a.tier < b.tier }
            switch (recents[a.candidate.id], recents[b.candidate.id]) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.index < b.index
            }
        }.map(\.candidate)
    }
}
