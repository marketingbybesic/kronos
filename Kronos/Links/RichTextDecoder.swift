// Kronos/Links/RichTextDecoder.swift. Pure `Data` -> plain-text decode, kept in its own file
// (Foundation + AppKit only, no SwiftUI/KronosCore) so
// `scripts/richtext-decoder-selftest.swift` compiles and exercises it standalone, the same way
// `Kronos/Shared/DropClassifier.swift` supports `scripts/dropclassifier-selftest.swift`.
//
// Root cause of a real notes-integration bug: a Notes drag whose provider offers ONLY
// `.rtf`/`.html` (no plain text, no URL, no known Notes UTI) loaded nothing, so
// `DropClassifier` had no payload to fall back to and the drop was silently swallowed. This
// decoder gave that (now-deleted; the drag path was replaced by an explicit "Link Apple note"
// button) caller a plain-text fallback to feed instead; it stays because
// `Kronos/List/FileDropPasteboard.swift` still uses it for a file-drop's rtf/html body.
import Foundation
import AppKit

enum RichTextDecoder {
    /// Decodes RTF or HTML bytes to plain text via `NSAttributedString`. Never throws: garbage
    /// input (a truncated drag payload, an unsupported encoding) returns nil rather than
    /// crashing the drop handler.
    ///
    /// Found by this file's own self-test: HTML with no `<meta charset>` declaration (the
    /// shape `NSItemProvider.loadDataRepresentation` hands back — no HTTP header either)
    /// makes `NSAttributedString`'s importer guess Windows-1252/Latin-1 instead of the UTF-8
    /// a Notes drag actually carries, mangling every dropped Croatian title (š/č/ć/ž/đ become
    /// "Å¡" etc.) — the exact text this decoder exists to read. UTF-8
    /// is tried first since that IS what `NSItemProvider`/Notes emit; a plain import without
    /// the hint is the fallback, for the rare source that really did declare another encoding.
    static func plainText(from data: Data, isHTML: Bool) -> String? {
        let docType: NSAttributedString.DocumentType = isHTML ? .html : .rtf
        let utf8Hinted = try? NSAttributedString(
            data: data,
            options: [.documentType: docType, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        guard let attributed = utf8Hinted ?? (try? NSAttributedString(data: data, options: [.documentType: docType], documentAttributes: nil)) else {
            return nil
        }
        // HTML's implicit block-level wrapping (<html><body><p>...) adds a trailing newline
        // AppKit's own converter emits after the last block; a chip title built from this
        // text should never carry it.
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Notes file promise (the machinery `receivePromisedFiles` writes to disk) is most
    /// likely `.rtfd` — a DIRECTORY, not a plain file — which the
    /// `Data`-based `plainText(from:isHTML:)` above cannot read at all (`Data(contentsOf:)`
    /// on a directory throws). `NSAttributedString(url:options:documentAttributes:)` reads a
    /// `.rtfd` bundle directly by URL (measured standalone: writes a real rtfd, reads it back
    /// correctly — no manual `TXT.rtf` digging needed), and the same initializer also handles
    /// plain `.rtf`/`.html`/`.txt` by URL, so one code path covers every text-bearing promise
    /// extension. `.pdf` is NOT extracted here (a PDF's "plain text" is a lossy render, not
    /// what a promised note file actually carries as its readable content) — the caller uses
    /// the promise's own file name as the title candidate for that case instead.
    static func plainText(fromFileURL url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard ext != "pdf" else { return nil }
        guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
            return nil
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
