// Kronos/Detail/FirstMoveLogic.swift
// Pure decision for "First move" — the inspector section, the Now card and the menu bar all go
// through it (via FirstMoveText.swift), so they can never disagree. Precedence, highest first:
//   1. an open subtask            -> that subtask, read-only (reordering subtasks changes it)
//   2. an attachment               -> "Reply to: <subject>" (email) beats "Review file: <name>" /
//                                     "Open folder: <name>" beats note / web link; read-only,
//                                     like a subtask: the attachment IS the concrete first step
//   3. the stored first move        -> editable, unless it is one of the generator's generic
//                                     placeholder sentences ("Open the notes for this task and
//                                     write the first line"), which counts as empty
//   4. nothing                      -> editable and empty; the inspector shows its generic placeholder
//                                     (a "Review: <title>" hint restated the title and was removed)
// Foundation only (no SwiftUI/KronosCore): scripts/firstmove-selftest.swift compiles this file
// standalone against a hand-written table. The caller passes `firstMoveIsGeneric` (Core's
// `DeterministicFirstMove.isGenericTemplate`) and plain attachment kinds.
import Foundation

public enum FirstMoveSuggestion: Equatable {
    case replyTo(String)
    case reviewFile(String)
    case openFolder(String)
    case readNote(String)
    case openLink(String)
}

/// What the First move surface renders.
public enum FirstMoveDisplay: Equatable {
    /// Read-only: the next open subtask.
    case fromSubtask(title: String)
    /// Read-only: derived from the task's attachment.
    case fromAttachment(FirstMoveSuggestion)
    /// Editable: the stored move (nil = none, or only a generic placeholder), with the hint
    /// shown while it is empty.
    case editable(text: String?, hint: FirstMoveSuggestion?)
}

public enum FirstMoveAttachmentKind: Equatable {
    case email, file, folder, note, webLink, other
}

public enum FirstMoveLogic {
    public static func display(nextOpenSubtaskTitle: String?,
                               firstMove: String?,
                               firstMoveIsGeneric: Bool = false,
                               attachments: [(kind: FirstMoveAttachmentKind, name: String)] = [],
                               taskTitle: String = "") -> FirstMoveDisplay {
        if let title = nextOpenSubtaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return .fromSubtask(title: title)
        }
        if let suggestion = suggestion(from: attachments) {
            return .fromAttachment(suggestion)
        }
        let stored = firstMove?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (stored?.isEmpty ?? true) || firstMoveIsGeneric ? nil : stored
        return .editable(text: text, hint: nil)
    }

    /// First email, else first file/folder, else first note/web link — in drop order.
    private static func suggestion(from attachments: [(kind: FirstMoveAttachmentKind, name: String)]) -> FirstMoveSuggestion? {
        let named = attachments.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if let a = named.first(where: { $0.kind == .email }) { return .replyTo(a.name) }
        if let a = named.first(where: { $0.kind == .file || $0.kind == .folder }) {
            return a.kind == .file ? .reviewFile(a.name) : .openFolder(a.name)
        }
        if let a = named.first(where: { $0.kind == .note || $0.kind == .webLink }) {
            return a.kind == .note ? .readNote(a.name) : .openLink(a.name)
        }
        return nil
    }
}
