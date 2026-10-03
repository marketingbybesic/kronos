// Part of TaskStore: editing the shared label vocabulary (rename, colour).
//
// Attaching and detaching a label on a task already exist as `addLabel(_:to:)` /
// `removeLabel(_:from:)` (TaskStoring); this file only adds what the label context
// menu needs on top: renaming a label and changing its colour. Each is ONE undo
// step, a no-op change pushes nothing, and the label keeps its id.

import Foundation
import SwiftData

/// What `renameLabel` did. Anything but `.renamed` changed nothing and pushed no undo step.
public enum LabelRenameResult: Equatable, Sendable {
    case renamed
    /// The trimmed name equals the current name exactly.
    case unchanged
    /// The trimmed name is empty.
    case empty
    /// Another label already has this name under the merge key (case and diacritics folded).
    case duplicate
    case notFound
}

extension TaskStore {
    /// All labels in the store, ordered by name.
    public func labels() -> [KLabel] {
        let descriptor = FetchDescriptor<KLabel>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// A label by id, or nil.
    public func label(id: UUID) -> KLabel? {
        let predicate = #Predicate<KLabel> { $0.id == id }
        return (try? context.fetch(FetchDescriptor<KLabel>(predicate: predicate)))?.first
    }

    /// Rename a label. A case-only change ("work" to "Work") is allowed; a name another
    /// label already owns under the merge key is refused so two labels never collapse
    /// into one on the next merge. REGISTERS UNDO (one step) only when it renames.
    @discardableResult
    public func renameLabel(_ id: UUID, to name: String) -> LabelRenameResult {
        guard let label = label(id: id) else { return .notFound }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed == label.name { return .unchanged }
        let key = KLabel(name: trimmed).mergeKey
        if labels().contains(where: { $0.id != id && $0.mergeKey == key }) { return .duplicate }

        let oldName = label.name
        let oldUpdated = label.updatedAt
        func apply(_ value: String) {
            guard let l = self.label(id: id) else { return }
            l.name = value
            l.updatedAt = Date()
        }
        apply(trimmed)
        saveContext()
        pushReversible("Rename Label", touching: [id], clearRedo: true, undo: {
            guard let l = self.label(id: id) else { return }
            l.name = oldName
            l.updatedAt = oldUpdated
        }, redo: { apply(trimmed) })
        return .renamed
    }

    /// Set a label's colour from `#RRGGBB` or `RRGGBB` (any case); stored as `#RRGGBB`
    /// upper case. Returns true when it changed. An invalid value, an unknown label or
    /// the colour the label already has changes nothing and pushes no undo step.
    /// REGISTERS UNDO (one step) when it changes.
    @discardableResult
    public func setLabelColor(_ id: UUID, hex: String) -> Bool {
        guard let label = label(id: id), let normal = Self.normalizedHex(hex),
              normal != label.colorHex.uppercased() else { return false }
        let oldHex = label.colorHex
        let oldUpdated = label.updatedAt
        func apply(_ value: String) {
            guard let l = self.label(id: id) else { return }
            l.colorHex = value
            l.updatedAt = Date()
        }
        apply(normal)
        saveContext()
        pushReversible("Label Colour", touching: [id], clearRedo: true, undo: {
            guard let l = self.label(id: id) else { return }
            l.colorHex = oldHex
            l.updatedAt = oldUpdated
        }, redo: { apply(normal) })
        return true
    }

    static func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s
    }
}
