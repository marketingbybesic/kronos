// Kronos/List/FileDropPasteboard.swift. Foundation + AppKit only (no SwiftUI/KronosCore) so
// `scripts/filedroppasteboard-selftest.swift` compiles and exercises it standalone, the same
// way `Kronos/Shared/DropClassifier.swift` supports `scripts/dropclassifier-selftest.swift`
// and `Kronos/Links/RichTextDecoder.swift` supports its own self-test.
//
// ROOT CAUSE of a real bug where stored file links ended up as `link://web|Untitled|` — kind
// `.web`, empty reference: that is only possible if `ContextLinkDropModifier.classify`
// (ListDrop.swift) loaded NOTHING from the NSItemProvider (fileURL/url/text all nil) and fell
// through to `DropClassifier`'s empty `.text` fallback. `NSItemProvider.loadObject`/`loadItem`
// were silently returning nil for real Finder drops; `NSPasteboard(name: .drag)` read
// SYNCHRONOUSLY inside the `onDrop` closure (before the drag session can be torn down) is the
// reliable AppKit route and is now tried first — see `ContextLinkDropModifier.body(content:)`
// in ListDrop.swift.
import Foundation
import AppKit

enum FileDropPasteboard {
    /// A file/folder drop's fields, independent of `ContextLink` (KronosCore) so this whole
    /// file can compile and be tested without the package — `ListDrop.swift`'s
    /// `FileDropPasteboard.Fields.contextLink` is the one place that converts it.
    struct Fields: Equatable {
        let isDirectory: Bool
        /// The base64 security-scoped bookmark, or (if bookmarking failed) the raw path —
        /// same fallback `ContextLinkDropModifier.contextLink(from:)` already uses for the
        /// `NSItemProvider` path, so a link's `reference` shape doesn't depend on which route
        /// produced it.
        let reference: String
        let displayName: String
    }

    /// Real file URLs only (`.urlReadingFileURLsOnly`) — a web URL or plain text on the same
    /// pasteboard is left for the `NSItemProvider` fallback path to classify.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// Builds `Fields` for one already-resolved file URL: stats it for file-vs-folder,
    /// bookmarks it (falls back to the raw path if bookmarking fails), and uses
    /// `lastPathComponent` as the display name (matches `DropClassifier`'s own file-title
    /// rule) — falling back to the full path only when that's empty (the filesystem root).
    static func fields(for url: URL) -> Fields {
        let path = url.path
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let reference = bookmarkBase64(forPath: path) ?? path
        let title = url.lastPathComponent
        return Fields(isDirectory: isDirectory.boolValue, reference: reference, displayName: title.isEmpty ? path : title)
    }

    /// Same security-scoped bookmark `ContextLinkDropModifier` builds for the `NSItemProvider`
    /// path — kept here too rather than shared, so this file has zero dependency on
    /// `ListDrop.swift` and stays standalone-compilable for its self-test.
    private static func bookmarkBase64(forPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        return data.base64EncodedString()
    }
}
