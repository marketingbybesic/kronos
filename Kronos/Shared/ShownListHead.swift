import Foundation

/// The top of the list on screen: its display name and the first few task ids in display order.
/// The list publishes it; "next" is the first eligible row of it (see `NextEligibility`).
struct ShownListHead: Equatable, Sendable {
    /// Most ids kept: enough to skip a few ineligible rows, small enough to publish on every change.
    static let maxIDs = 8

    var listName: String
    var ids: [UUID]

    static let empty = ShownListHead(listName: "", ids: [])

    init(listName: String, ids: [UUID]) {
        self.listName = listName
        self.ids = Array(ids.prefix(Self.maxIDs))
    }
}
