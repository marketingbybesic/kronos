// Kronos/App/ServicesProvider.swift
// Services menu: "Add to Kronos" and "Capture in Kronos" on selected text in any app.
// The menu entries are declared in project.yml (NSServices); NSMessage names below match.
import AppKit
import KronosCore

final class ServicesProvider: NSObject {
    private let model: AppModel
    init(model: AppModel) { self.model = model }

    /// The first line is read like any add field (`#project` or `#area`, `@label`, priority, dates,
    /// "a > b" subtasks: URLSchemeRouter.add -> QuickAddCreate, grammar v2); the rest is its notes.
    @objc func addToKronos(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string) else { return }
        guard let split = EntryText.servicesSplit(text),
              let title = KronosURLParser.clean(split.line, cap: KronosURLParser.maxTitle, singleLine: true) else { return }
        let rest = KronosURLParser.clean(split.notes, cap: KronosURLParser.maxNotes, singleLine: false)
        MainActor.assumeIsolated {
            guard AppDelegate.shared?.launchFailure == nil else { return }
            URLSchemeRouter.add(title: title, notes: rest, project: nil, due: nil, model: model)
            MenuBarFlash.flashIfBackground()
        }
    }

    /// "Add link to Kronos" on a file in Finder or a link in a browser: one new task per item, titled
    /// by its name, with the file or web chip already on it. Anything without a usable reference
    /// (plain text, an unreadable item) is ignored, never a task with an empty chip.
    @objc func addLinkToKronos(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        MainActor.assumeIsolated {
            guard AppDelegate.shared?.launchFailure == nil else { return }
            if !Self.addLinks(from: pboard, model: model).isEmpty { MenuBarFlash.flashIfBackground() }
        }
    }

    /// The part of the service that does not depend on how it was called (the live test feeds it a
    /// pasteboard of its own).
    @MainActor @discardableResult
    static func addLinks(from pasteboard: NSPasteboard, model: AppModel) -> [KTask] {
        guard case .external(let items) = DropZonePayloadReader.read(pasteboard) else { return [] }
        let usable = items.filter { item in
            guard let link = item.link, !link.reference.isEmpty else { return false }
            return !item.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !usable.isEmpty else { return [] }
        let store = model.store
        var made: [KTask] = []
        store.groupedUndo(String(localized: "undo.quickadd")) {
            for item in usable {
                guard let link = item.link else { continue }
                made.append(store.create(title: item.title, notes: link.appending(to: ""), project: nil,
                                         status: .todo, priority: .none, dueDay: nil))
            }
        }
        guard let first = made.first else { return [] }
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "app.url.added"), first.title))
        return made
    }

    @objc func captureInKronos(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let raw = pboard.string(forType: .string),
              let text = KronosURLParser.clean(raw, cap: KronosURLParser.maxCapture, singleLine: false) else { return }
        MainActor.assumeIsolated {
            guard AppDelegate.shared?.launchFailure == nil else { return }
            model.openCapture(with: text)
            AppDelegate.shared.bringForward()
        }
    }
}
