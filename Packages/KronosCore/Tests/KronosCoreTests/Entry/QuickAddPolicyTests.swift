import Testing
@testable import KronosCore

/// The quick add panel's decisions, every case by hand.
struct QuickAddPolicyTests {
    typealias P = QuickAddPolicy

    /// ⏎ add and close, ⌘⏎ add and stay, ⌥⏎ add and keep pills, ⏎ on an empty field closes.
    @Test func returnTable() {
        let table: [(P.ReturnKey, Bool, P.ReturnAction)] = [
            (.plain, true, .addAndClose),
            (.command, true, .addAndStay),
            (.option, true, .addAndKeepPills),
            (.plain, false, .close),
            (.command, false, .ignore),
            (.option, false, .ignore),
        ]
        for (key, hasText, action) in table {
            #expect(P.onReturn(key, hasText: hasText) == action, "\(key) hasText=\(hasText)")
        }
    }

    /// A click into another app must keep its focus; finishing in the panel gives focus back.
    @Test func reactivation() {
        #expect(P.reactivatesPreviousApp(.finished) == true)
        #expect(P.reactivatesPreviousApp(.resignedKey) == false)
    }

    /// The legend opens by itself for the first three adds, then only when pinned.
    @Test func legendAutoOpen() {
        let table: [(Bool, Int, Bool)] = [
            (false, 0, true), (false, 1, true), (false, 2, true), (false, 3, false), (false, 40, false),
            (true, 0, true), (true, 3, true), (true, 40, true),
        ]
        for (pinned, adds, opens) in table {
            #expect(P.legendOpens(pinned: pinned, addsSoFar: adds) == opens, "pinned=\(pinned) adds=\(adds)")
        }
    }

    @Test func acknowledgementDestination() {
        #expect(P.destination(projectName: "Acme", areaName: "Work", isWaiting: true, dueDay: 5) == .project("Acme"))
        #expect(P.destination(projectName: nil, areaName: "Work", isWaiting: true, dueDay: 5) == .area("Work"))
        #expect(P.destination(projectName: "", areaName: nil, isWaiting: true, dueDay: 5) == .waiting)
        #expect(P.destination(projectName: nil, areaName: nil, isWaiting: false, dueDay: 5) == .day(5))
        #expect(P.destination(projectName: nil, areaName: "", isWaiting: false, dueDay: nil) == .inbox)
    }
}
