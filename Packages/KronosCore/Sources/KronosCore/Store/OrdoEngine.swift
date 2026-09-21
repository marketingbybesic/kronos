import Foundation

/// The single source of truth for ORDO ordering: nothing outside OrdoEngine
/// writes `ordoIndex`. Exposes the queue and the Bar target: the first
/// element whose status is in KStatus.active (NOT simply ordo[0]).
@MainActor
@Observable
public final class OrdoEngine {
    private unowned let store: TaskStore

    public init(store: TaskStore) {
        self.store = store
    }

    /// The full ORDO queue in §5.3 ordo order (closed rows included until
    /// "Clear done" or the day-change sweep removes them).
    public var queue: [KTask] {
        store.allTasks()
            .filter { $0.ordoIndex != nil }
            .sorted(by: Ordering.ordo)
    }

    /// Bar target: first active-status row in ordo order.
    public var current: KTask? {
        queue.first { KStatus.active.contains($0.status) }
    }

    /// Complete from the Bar or the ORDO view. Posts .kronosDidCompleteFromBar.
    public func complete() {
        guard let t = current else { return }
        store.complete(t.id)
        NotificationCenter.default.post(name: .kronosDidCompleteFromBar,
                                        object: nil,
                                        userInfo: ["taskID": t.id])
    }

    /// Skip = move the current top task to the end of ORDO.
    public func skip() {
        guard let t = current else { return }
        store.sendToOrdo(t.id, top: false) // append semantics: moves to end
    }

    /// Nothing outside OrdoEngine writes ordoIndex — this is the only door,
    /// and it delegates to the store's append/pushTop arithmetic.
    public func push(_ id: UUID, top: Bool = false) {
        store.sendToOrdo(id, top: top)
    }

    public func remove(_ id: UUID) {
        store.removeFromOrdo(id)
    }

    public func clearDone() {
        store.clearDoneFromOrdo()
    }
}