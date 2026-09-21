import Foundation
import Testing
@testable import KronosCore

@MainActor
@Suite(.serialized) struct CompletionAnnouncementTests {
    private func count(_ name: Notification.Name, during body: () -> Void) -> Int {
        var n = 0
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in n += 1 }
        body()
        NotificationCenter.default.removeObserver(token)
        return n
    }

    @Test func userCompletionAnnouncesOnceMachineCompletionNever() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.create(title: "Call Alex")
        let b = store.create(title: "Invoice Acme")
        #expect(count(.kronosTaskDidComplete) { store.complete(a.id) } == 1)
        #expect(count(.kronosTaskDidComplete) { store.complete(a.id) } == 0, "already done: no second cue")
        #expect(count(.kronosTaskDidComplete) { store.completeNoUndo(b.id) } == 0, "machine write must stay silent")
    }

    @Test func createAnnouncesOncePerTask() throws {
        let store = try TaskStore(inMemory: true)
        #expect(count(.kronosTaskDidCreate) { _ = store.create(title: "Call Alex") } == 1)
    }
}
