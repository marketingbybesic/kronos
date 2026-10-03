import Testing
import Foundation
@testable import KronosCore

/// The "Waits on" picker offers child tasks too, named "Parent › Child".
///
///  Fixture: "Write report" (the task being edited)
///           "Book venue"  children: "Call hotel" (open) | "Pay deposit" (done)
///           "Plan trip"   children: "Pack bags" (open), "Pack bags" waits on "Write report"
///           "Old chore"   (done)
@MainActor
@Suite("WaitsOnChildCandidatesTests")
struct WaitsOnChildCandidatesTests {

    @MainActor private struct World {
        let store: TaskStore
        let byTitle: [String: KTask]
        func t(_ title: String) -> KTask { byTitle[title]! }
        func names(_ query: String, limit: Int = 8) -> [String] {
            store.waitsOnCandidates(for: t("Write report").id, query: query, limit: limit).map(\.waitsOnDisplayName)
        }
    }

    private func world() throws -> World {
        let store = try TaskStore(inMemory: true)
        var all: [String: KTask] = [:]
        func parent(_ title: String, status: KStatus = .todo) -> KTask {
            let t = store.createNoUndo(title: title, project: nil, status: status)
            all[title] = t
            return t
        }
        func child(_ title: String, of p: KTask, status: KStatus = .todo) -> KTask {
            let c = store.addSubtaskNoUndo(p.id, title: title)!
            c.status = status
            all[title] = c
            return c
        }
        let write = parent("Write report")
        let venue = parent("Book venue")
        _ = child("Call hotel", of: venue)
        _ = child("Pay deposit", of: venue, status: .done)
        let trip = parent("Plan trip")
        let pack = child("Pack bags", of: trip)
        _ = parent("Old chore", status: .done)
        store.setWaitsOnNoUndo(pack.id, [write.id])
        return World(store: store, byTitle: all)
    }

    @Test func childrenAreOfferedWithTheirParentsName() throws {
        let w = try world()
        // Open tasks and open children, sorted by the shown name. "Pack bags" waits on the
        // edited task, so offering it would close a loop.
        #expect(w.names("") == ["Book venue", "Book venue › Call hotel", "Plan trip"])
    }

    @Test func searchMatchesTheParentPartToo() throws {
        let w = try world()
        #expect(w.names("hotel") == ["Book venue › Call hotel"])
        #expect(w.names("venue") == ["Book venue", "Book venue › Call hotel"])
        #expect(w.names("deposit") == [])
        #expect(w.names("bags") == [])
    }

    @Test func aChosenChildIsNotOfferedAgainAndAcceptsAsADependency() throws {
        let w = try world()
        let hotel = w.t("Call hotel")
        #expect(w.store.setWaitsOn(w.t("Write report").id, [hotel.id]))
        #expect(w.t("Write report").waitsOn == [hotel.id])
        #expect(w.names("") == ["Book venue", "Plan trip"])
        #expect(w.store.isBlocked(w.t("Write report").id))
    }

    @Test func theLimitCaps() throws {
        let w = try world()
        #expect(w.names("", limit: 1) == ["Book venue"])
    }
}
