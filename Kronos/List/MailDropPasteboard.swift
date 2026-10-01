// Kronos/List/MailDropPasteboard.swift. Foundation + AppKit only (no SwiftUI/KronosCore), so
// `scripts/maildrop-selftest.swift` compiles it standalone against a private named pasteboard,
// the same pattern as FileDropPasteboard.swift.
//
// What this reads from the SYSTEM drag pasteboard, synchronously inside `onDrop`:
// - Apple Mail messages: every pasteboard item whose `public.url` is a `message:` URL (Mail
//   puts one per dragged message; opening it shows exactly that message in Mail). The subject
//   comes from `public.url-name`, else the item's plain text when it is not the URL itself.
//   The previous build only looked for guessed type ids ("com.apple.mail.message") and never
//   matched a real Mail drag.
// - A subtask row being dragged for reorder inside Kronos: its plain text is
//   `subtaskDragPrefix + uuid`, so no drop target mistakes it for text to attach.
import Foundation
import AppKit

enum MailDropPasteboard {
    struct Message: Equatable {
        /// `message:%3C<Message-ID>%3E` (or the `message://` spelling) exactly as Mail gave it.
        let url: String
        /// nil when Mail offered no readable subject: the caller supplies a localised fallback.
        let subject: String?
    }

    static let subtaskDragPrefix = "kronos-subtask:"
    private static let urlName = NSPasteboard.PasteboardType("public.url-name")

    static func isMessageURL(_ s: String) -> Bool {
        s.lowercased().hasPrefix("message:")
    }

    /// One entry per dragged Mail message, in drag order; empty for any other drag.
    static func messages(from pasteboard: NSPasteboard) -> [Message] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let url = item.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isMessageURL(url) else { return nil }
            let candidates = [item.string(forType: urlName), item.string(forType: .string)]
            let subject = candidates.lazy
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !isMessageURL($0) }
            return Message(url: url, subject: subject)
        }
    }

    /// The subtask id when this drag is Kronos's own subtask-row drag, else nil.
    static func subtaskID(from pasteboard: NSPasteboard) -> UUID? {
        guard let s = pasteboard.string(forType: .string), s.hasPrefix(subtaskDragPrefix) else { return nil }
        return UUID(uuidString: String(s.dropFirst(subtaskDragPrefix.count)))
    }

    /// Type names only (never contents) of every item — one log line per drop, so a source
    /// that offers something unexpected can be diagnosed from a single user attempt.
    static func typesSummary(_ pasteboard: NSPasteboard) -> String {
        (pasteboard.pasteboardItems ?? []).enumerated()
            .map { "item\($0.offset)=[" + $0.element.types.map(\.rawValue).joined(separator: ",") + "]" }
            .joined(separator: " ")
    }
}
