// Kronos/Detail/LinkInput.swift. Foundation only (no SwiftUI/KronosCore) so
// `scripts/linkinput-selftest.swift` compiles and exercises the REAL file standalone.
// Two pure pieces of the inspector: turning typed/pasted text into a web link or an existing
// file (an empty or malformed reference is rejected here, never stored), and turning a drag
// position over the steps list into a reorder.
import Foundation

enum LinkInput {
    struct Web: Equatable {
        let reference: String
        /// The chip label: the host without a leading "www.", or the address of a mailto: link.
        let label: String
    }

    /// Typed text -> a web link. A bare host ("example.com/page") gets https://. Rejects empty
    /// text, text with whitespace inside, an unknown scheme and a URL without a host.
    static func web(_ raw: String) -> Web? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("mailto:") {
            let address = String(text.dropFirst("mailto:".count))
            guard address.contains("@"), !address.hasPrefix("@"), !address.hasSuffix("@") else { return nil }
            return Web(reference: text, label: address)
        }
        let full: String
        if text.contains("://") {
            full = text
        } else if text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), !text.hasPrefix("/") {
            full = "https://" + text
        } else {
            return nil
        }
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return Web(reference: full, label: host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    /// Pasted text -> a web link, only when it already IS a URL (http/https with a scheme): a
    /// pasted sentence or a bare word with a dot must not silently become a chip.
    static func pastedURL(_ raw: String) -> Web? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return web(text)
    }

    /// A typed path ("~/Documents/a.pdf", "/home/x/a.pdf", or "file:///…") -> the URL when
    /// something exists there right now, else nil.
    static func existingFile(atTypedPath raw: String) -> (url: URL, isDirectory: Bool)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path
        }
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return (URL(fileURLWithPath: path), isDirectory.boolValue)
    }
}

/// Drag-reorder of the inspector's steps: where the insertion line goes and what the store
/// should be told. Slot `s` means "between row s-1 and row s" (0 = above the first row,
/// `count` = below the last).
enum StepReorder {
    /// Slot for a pointer at `y` (row-local, top origin) over row `rowIndex`: upper half is
    /// the slot above the row, lower half the slot below it.
    static func slot(rowIndex: Int, y: Double, rowHeight: Double) -> Int {
        y < rowHeight / 2 ? rowIndex : rowIndex + 1
    }

    /// The `before:` argument for `reorderSubtask`, or nil when dropping `dragged` at `slot`
    /// leaves the order unchanged (dropped on itself or on a neighbouring slot) or the id is
    /// not in `order`. `.some(nil)` means "to the end".
    static func move(order: [UUID], dragged: UUID, slot: Int) -> UUID?? {
        guard let from = order.firstIndex(of: dragged), (0...order.count).contains(slot) else { return nil }
        if slot == from || slot == from + 1 { return nil }
        return .some(slot < order.count ? order[slot] : nil)
    }
}
