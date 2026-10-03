import Testing
import Foundation
@testable import KronosCore

/// `#` in the entry field ranks projects the way every project picker does (ProjectRanking):
/// tier first, recent use inside a tier, manual order last; an empty `#` lists recents first.
/// Expected orders are written by hand.
struct EntryProjectRankingTests {
    static let older = Date(timeIntervalSince1970: 1_790_000_000)
    static let newer = Date(timeIntervalSince1970: 1_790_500_000)

    static let directory = EntryDirectory(
        projects: [
            EntryName("Nova notes", id: UUID()),
            EntryName("Novarad", id: UUID(), lastUsed: older),
            EntryName("Home", id: UUID(), lastUsed: newer),
            EntryName("Nova", id: UUID()),
        ],
        areas: [EntryName("Kuća", id: UUID())])

    static func names(_ text: String) -> [String] {
        EntrySuggester.suggest(text: text, caret: text.utf16.count, directory: directory, today: 20000,
                               languages: ["en", "hr"], limit: 10)
            .items.filter { !$0.isCreate }.map(\.title)
    }

    @Test func exactBeatsARecentPrefixThenRecencyInsideTheTier() {
        #expect(Self.names("#nova") == ["Nova", "Novarad", "Nova notes"])
    }

    @Test func emptyHashListsRecentsFirstThenManualOrderThenAreas() {
        #expect(Self.names("#") == ["Home", "Novarad", "Nova notes", "Nova", "Kuća"])
    }

    /// The same query in a project picker gives the same projects in the same order.
    @Test func agreesWithThePickers() {
        let candidates = Self.directory.projects.map { ProjectRanking.Candidate(id: $0.id!, name: $0.name) }
        let recents = Dictionary(uniqueKeysWithValues: Self.directory.projects.compactMap { n in n.lastUsed.map { (n.id!, $0) } })
        let picker = ProjectRanking.rank(query: "nova", projects: candidates, recents: recents).map(\.name)
        #expect(Self.names("#nova") == picker)
    }

    /// A directory built without ids still ranks (stable stand-in ids).
    @Test func namesWithoutIDs() {
        let d = EntryDirectory(projects: [EntryName("Beta"), EntryName("Bet")])
        let items = EntrySuggester.suggest(text: "#bet", caret: 4, directory: d, today: 20000, languages: ["en"], limit: 10)
            .items.filter { !$0.isCreate }.map(\.title)
        #expect(items == ["Bet", "Beta"])
    }
}
