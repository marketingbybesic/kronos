import Foundation

/// Which task the inspector shows, and so which task every inspector action targets: the child
/// being inspected (child mode) while it still belongs to the selected task, else the selected
/// task itself. `nil` when nothing live is selected. One rule for the screen and for every
/// action, so a link, note, move or delete can never land on the parent of a shown child.
public enum InspectedTask {
    public static func resolve(selected: KTask?, inspectedChildID: UUID?) -> KTask? {
        guard let selected, selected.deletedAt == nil else { return nil }
        if let id = inspectedChildID,
           let child = selected.orderedChildren.first(where: { $0.id == id }), child.deletedAt == nil {
            return child
        }
        return selected
    }
}
