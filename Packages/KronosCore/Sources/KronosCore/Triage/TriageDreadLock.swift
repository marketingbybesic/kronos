import Foundation

/// The dread flag has a lock of its own: a person who switched "avoiding it" off has decided,
/// and a later triage must not set it again. The lock is a `dread` token in the same list as the
/// field locks (`KTask.lockedFieldsRaw`). It is not a `TriageFieldKind` case on purpose: that enum
/// is every field a triage result fills, and a case here would turn every exhaustive switch over
/// it (the card, the coach section, the revert) into one more field to render.
extension KTask {
    public static let dreadLockToken = "dread"

    /// True when the person switched dread off by hand and triage must leave it alone.
    public var dreadLocked: Bool {
        lockedFieldsRaw.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == Self.dreadLockToken }
    }
}

extension TriageFieldKind {
    /// `encoded` (a fresh `encode(...)` result) with the dread token of `old` carried over, so
    /// rewriting the field locks never drops it.
    static func keepingDreadToken(from old: String, in encoded: String) -> String {
        let hadToken = old.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == KTask.dreadLockToken }
        guard hadToken else { return encoded }
        return encoded.isEmpty ? KTask.dreadLockToken : encoded + "," + KTask.dreadLockToken
    }
}

extension TaskStore {
    /// Locks dread on task `id` against triage. Bookkeeping, not an edit: no undo step, and
    /// nothing happens when it is locked already or the task is unknown.
    public func lockDread(on id: UUID) {
        guard let t = taskIncludingDeleted(id), !t.dreadLocked else { return }
        updateNoUndo(id) { t in
            t.lockedFieldsRaw = t.lockedFieldsRaw.isEmpty ? KTask.dreadLockToken : t.lockedFieldsRaw + "," + KTask.dreadLockToken
        }
    }

    /// Lifts the dread lock (the person switched dread on again).
    public func unlockDread(on id: UUID) {
        guard let t = taskIncludingDeleted(id), t.dreadLocked else { return }
        updateNoUndo(id) { t in
            t.lockedFieldsRaw = t.lockedFieldsRaw.split(separator: ",")
                .filter { $0.trimmingCharacters(in: .whitespaces) != KTask.dreadLockToken }
                .joined(separator: ",")
        }
    }
}
