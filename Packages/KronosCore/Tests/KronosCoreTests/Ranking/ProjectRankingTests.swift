import Testing
import Foundation
@testable import KronosCore

/// Hand-written tables: the pool, the recents and every expected order below are written out from the
/// rule (tier first, recency inside a tier, recents first for an empty query), never read back from
/// `ProjectRanking`.
@MainActor
struct ProjectRankingTests {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")! }

    /// Manual order = the order of this array.
    private let pool: [ProjectRanking.Candidate] = [
        .init(id: ProjectRankingTests.id(0), name: "Atlas", areaName: "Work"),
        .init(id: ProjectRankingTests.id(1), name: "Kodiak", areaName: "Work"),
        .init(id: ProjectRankingTests.id(2), name: "Kitchen Remodel", areaName: "Home"),
        .init(id: ProjectRankingTests.id(3), name: "Acme Koda", areaName: nil),
        .init(id: ProjectRankingTests.id(4), name: "Škola Kod", areaName: nil),
        .init(id: ProjectRankingTests.id(5), name: "Hit List", areaName: nil),
        .init(id: ProjectRankingTests.id(6), name: "Marketing Q4", areaName: "Work"),
    ]

    private func recents(_ pairs: [(Int, TimeInterval)]) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: pairs.map { (Self.id($0.0), Date(timeIntervalSince1970: $0.1)) })
    }

    private func names(_ query: String, _ recents: [UUID: Date] = [:]) -> [String] {
        ProjectRanking.rank(query: query, projects: pool, recents: recents).map(\.name)
    }

    /// Kitchen Remodel used last (300), then Atlas (200), then Marketing Q4 (100).
    private var lately: [UUID: Date] { recents([(2, 300), (0, 200), (6, 100)]) }

    @Test func emptyQueryListsRecentsFirstThenManualOrder() {
        #expect(names("", lately) == ["Kitchen Remodel", "Atlas", "Marketing Q4", "Kodiak", "Acme Koda", "Škola Kod", "Hit List"])
        #expect(names("   ", lately) == names("", lately))
    }

    @Test func emptyQueryWithoutRecentsKeepsManualOrder() {
        #expect(names("") == ["Atlas", "Kodiak", "Kitchen Remodel", "Acme Koda", "Škola Kod", "Hit List", "Marketing Q4"])
        // Positive control: the recents are what change the order above.
        #expect(names("", lately) != names(""))
    }

    @Test func tierBeatsRecency() {
        // kod: prefix Kodiak, word-prefix Acme Koda then Škola Kod (manual order), fuzzy Kitchen Remodel
        // (k, o, d in order) even though it is the most recently used project.
        #expect(names("kod", lately) == ["Kodiak", "Acme Koda", "Škola Kod", "Kitchen Remodel"])
    }

    @Test func recencyBreaksTiesInsideATier() {
        let skolaFirst = recents([(4, 400)])
        #expect(names("kod", skolaFirst) == ["Kodiak", "Škola Kod", "Acme Koda", "Kitchen Remodel"])
        // Positive control: without that recent entry the same query orders Acme Koda first.
        #expect(names("kod") == ["Kodiak", "Acme Koda", "Škola Kod", "Kitchen Remodel"])
    }

    @Test func oneLetterUsesPrefixWordPrefixAndContainsOnly() {
        // k: prefix (Kitchen Remodel is recent, so it leads Kodiak), word-prefix, contains. No fuzzy for one letter.
        #expect(names("k", lately) == ["Kitchen Remodel", "Kodiak", "Acme Koda", "Škola Kod", "Marketing Q4"])
    }

    @Test func exactNameWins() {
        #expect(names("KODIAK", lately) == ["Kodiak"])
        #expect(names("kodiak") == ["Kodiak"])
    }

    @Test func caseDiacriticsAndSeparatorsAreIgnored() {
        #expect(names("skola") == ["Škola Kod"])
        #expect(names("ŠKOLA kod") == ["Škola Kod"])
        #expect(names("hit-list") == ["Hit List"])
        #expect(names("hit_list") == ["Hit List"])
    }

    @Test func fuzzyLettersInOrderMatch() {
        // h then l: Hit List and Kitchen Remodel (k-i-t-c-h ... remode-l); the recent one first.
        #expect(names("hl", lately) == ["Kitchen Remodel", "Hit List"])
        #expect(names("lh") == [])
    }

    @Test func noMatchIsEmpty() {
        #expect(names("zzz", lately) == [])
    }

    @Test func emptyNamesAreNeverOffered() {
        let withBlank = pool + [.init(id: Self.id(7), name: "", areaName: nil)]
        let ranked = ProjectRanking.rank(query: "a", projects: withBlank, recents: [:])
        #expect(!ranked.contains { $0.name.isEmpty })
    }

    @Test func storeProjectsCarryTheirAreaName() throws {
        let store = try TaskStore(inMemory: true)
        let area = store.createArea(name: "Studio")
        let inArea = store.createProject(name: "Kodiak", area: area)
        let loose = store.createProject(name: "Kodiak Two")
        let ranked = ProjectRanking.rank(query: "kodiak", projects: [inArea, loose], recents: [:])
        #expect(ranked.map(\.name) == ["Kodiak", "Kodiak Two"])
        #expect(ranked.map(\.areaName) == ["Studio", nil])
    }
}
