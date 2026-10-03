// Kronos/Sidebar/SidebarTaskDrop.swift
// What a project row in the sidebar accepts: a task row dragged out of the list files the task into
// that project (one undo step, the usual pill), and a Finder folder links as a context folder as
// before. Anything else is refused, so the row never lights up for a drop it would ignore.
// The decision reads the drag pasteboard synchronously (`DropZonePayloadReader`), the same way the
// list's own drop targets do, and `perform` takes the pasteboard as an argument so the live test
// drives the exact code the delegate calls with a pasteboard of its own.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KronosCore

@MainActor
enum SidebarTaskDrop {
    enum Kind: Equatable {
        case task(UUID)
        case folder(URL)
    }

    /// What the pasteboard carries, as far as a project row is concerned; nil = refuse.
    static func kind(of pasteboard: NSPasteboard) -> Kind? {
        switch DropZonePayloadReader.read(pasteboard) {
        case .task(let id):
            return .task(id)
        case .external:
            return SidebarFolderDropClassifier.classify(FileDropPasteboard.fileURLs(from: pasteboard)).map(Kind.folder)
        case .subtask, .unsupported:
            return nil
        }
    }

    /// Applies the drop on `projectID`. True when something changed.
    @discardableResult
    static func perform(_ pasteboard: NSPasteboard, onProject projectID: UUID, model: AppModel) -> Bool {
        guard let kind = kind(of: pasteboard) else { return false }
        switch kind {
        case .task(let taskID):
            guard case .moved(let name) = SidebarStoreActions.moveTask(taskID, toProject: projectID, store: model.store) else {
                return false
            }
            model.didMutate()
            UndoToastCenter.shared.show(SidebarPillText.moved(toProject: name))
            return true
        case .folder(let url):
            guard let link = SidebarFolderDropClassifier.link(for: url) else { return false }
            model.coach.update { $0.projectFolders[projectID, default: []].append(link) }
            return true
        }
    }
}

struct SidebarProjectDropDelegate: DropDelegate {
    static let types: [UTType] = [.plainText, .fileURL]

    let projectID: UUID
    let model: AppModel
    /// The project row the drag is over, for the hairline outline; at most one row at a time.
    @Binding var targetID: UUID?

    private var pasteboard: NSPasteboard { NSPasteboard(name: .drag) }

    func validateDrop(info: DropInfo) -> Bool { SidebarTaskDrop.kind(of: pasteboard) != nil }

    func dropEntered(info: DropInfo) {
        if SidebarTaskDrop.kind(of: pasteboard) != nil { targetID = projectID }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let kind = SidebarTaskDrop.kind(of: pasteboard) else { return DropProposal(operation: .forbidden) }
        if case .task = kind { return DropProposal(operation: .move) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if targetID == projectID { targetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        targetID = nil
        return SidebarTaskDrop.perform(pasteboard, onProject: projectID, model: model)
    }
}
