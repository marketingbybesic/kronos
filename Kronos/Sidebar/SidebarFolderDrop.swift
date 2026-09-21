// Kronos/Sidebar/SidebarFolderDrop.swift
// Feature M (project half): classifying what got dropped on a project row, and turning a
// Finder folder URL into the security-scoped bookmark `ProjectFolderLink.finder` stores.
//
// Pure and file-system-free where it can be (`SidebarFolderDropClassifier`), so it is
// testable the same way `DropClassifier` is for task-row drops (`List/ListDrop.swift`) — this
// is the project-row / FOLDER-only sibling.
// A Finder FILE (not a directory) dropped on a project is ignored with no error (ledger
// scope), and an Apple Notes folder drag is intentionally NOT handled here: the brief says
// Notes-folder drags are undocumented and not to be depended on — folders are linked
// through the "Link Notes folder..." picker instead (SidebarProjectFolders.swift).
import Foundation
import KronosCore

enum SidebarFolderDropClassifier {
    /// What a drop of `[URL]` (SwiftUI `.dropDestination(for: URL.self)`) means for a
    /// project row: only a directory is a link; a plain file is silently ignored.
    static func classify(_ urls: [URL]) -> URL? {
        guard let url = urls.first, urls.count == 1 else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// Bookmarks a Finder folder URL for long-lived, security-scoped access, and builds the
    /// `ProjectFolderLink` `CoachSettings.projectFolders` stores. Returns nil (never throws)
    /// on an unreachable URL or a bookmark failure — the caller simply does not link it,
    /// matching every other "never crash on a folder we can't reach" rule in this feature.
    static func link(for url: URL) -> ProjectFolderLink? {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) else { return nil }
        return .finder(bookmark: bookmark, displayPath: url.path)
    }
}
