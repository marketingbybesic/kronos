// Kronos/Detail/FirstMoveText.swift — the ONE bridge from a live `KTask` to `FirstMoveLogic`
// and to the sentence every surface shows (inspector, Now card, menu bar title and popover).
// Kept apart from FirstMoveLogic.swift so that file stays Foundation-only for its self-test.
import Foundation
import KronosCore

extension FirstMoveLogic {
    /// `includeSubtask: false` is for the menu-bar title, which composes the next subtask
    /// separately (Settings > Ordo) and only wants the move itself.
    @MainActor
    static func display(for task: KTask, includeSubtask: Bool = true) -> FirstMoveDisplay {
        display(nextOpenSubtaskTitle: includeSubtask ? task.nextOpenSubtask?.title : nil,
                firstMove: task.firstMove,
                firstMoveIsGeneric: task.firstMove.map(DeterministicFirstMove.isGenericTemplate) ?? false,
                attachments: ContextLink.findAll(in: task.notes).map { ($0.firstMoveKind, $0.displayName) },
                taskTitle: task.title)
    }

    /// The sentence a read-only surface shows; nil only for a task with no title at all.
    @MainActor
    static func text(for task: KTask) -> String? {
        switch display(for: task) {
        case .fromSubtask(let title): title
        case .fromAttachment(let s): s.localized
        case .editable(let text, _): text
        }
    }
}

extension FirstMoveLogic {
    /// The move without the subtask rung and without the title hint: attachment suggestion or
    /// the stored (non-generic) move, else nil so the caller falls back to the task title.
    @MainActor
    static func moveText(for task: KTask) -> String? {
        switch display(for: task, includeSubtask: false) {
        case .fromAttachment(let s): s.localized
        case .editable(let text, _): text
        case .fromSubtask: nil
        }
    }
}

extension FirstMoveSuggestion {
    var localized: String {
        switch self {
        case .replyTo(let s): String(format: String(localized: "detail.firstmove.suggest.reply"), s)
        case .reviewFile(let s): String(format: String(localized: "detail.firstmove.suggest.file"), s)
        case .openFolder(let s): String(format: String(localized: "detail.firstmove.suggest.folder"), s)
        case .readNote(let s): String(format: String(localized: "detail.firstmove.suggest.note"), s)
        case .openLink(let s): String(format: String(localized: "detail.firstmove.suggest.link"), s)
        }
    }
}

private extension ContextLink {
    /// A dropped bare text is stored as `.web` with a non-URL reference: not a link to open.
    var firstMoveKind: FirstMoveAttachmentKind {
        switch kind {
        case .email: .email
        case .file: .file
        case .folder: .folder
        case .appleNote: .note
        case .web: reference.lowercased().hasPrefix("http") ? .webLink : .other
        }
    }
}
