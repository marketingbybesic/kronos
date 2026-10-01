// Kronos/Templates/TemplateStore.swift
// The app-side home of task templates: a JSON file `templates.json` in the per-bundle folder
// (`KronosStore.containerDirectory()` = Application Support/<Kronos | Kronos Demo>, and it
// honours KRONOS_STORE_DIR), so the demo and the real app never share one. NOT SwiftData:
// templates add no schema, so they cannot threaten a user's store.
//
// The shape, the quick add `/name` parser and `createFromTemplate` live in Core
// (Templates/TaskTemplate.swift) where they are unit tested; this file is only persistence
// and the observable list the UI reads.
import Foundation
import Observation
import KronosCore

extension Notification.Name {
    /// Palette "New from template…": QuickAddController opens the panel with `/` typed so the
    /// template list is showing. Raw value is the contract (see AppNotifications.swift).
    static let kronosNewFromTemplate = Notification.Name("kronosNewFromTemplate")
}

@MainActor
@Observable
final class TemplateStore {
    static let shared = TemplateStore()

    private(set) var templates: [TaskTemplate] = []
    /// nil = do not persist (snapshots, tests): the list lives in memory only.
    private let url: URL?

    init(url: URL? = TemplateStore.defaultURL()) {
        self.url = url
        load()
    }

    /// Hermetic processes (snapshot harness) must never read or write the real folder.
    nonisolated static func defaultURL() -> URL? {
        if ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil { return nil }
        return KronosStore.containerDirectory().appendingPathComponent(TemplateFile.fileName)
    }

    // MARK: Read / write

    private func load() {
        guard let url else { return }
        do {
            templates = try TemplateFile.read(from: url)
        } catch {
            // A file we cannot parse is never overwritten with an empty list: park it beside
            // the original so the user can still recover what they typed.
            let parked = url.deletingLastPathComponent().appendingPathComponent("templates.unreadable.json")
            try? FileManager.default.removeItem(at: parked)
            try? FileManager.default.moveItem(at: url, to: parked)
            templates = []
        }
    }

    private func persist() {
        guard let url else { return }
        try? TemplateFile.write(templates, to: url)
    }

    // MARK: Mutations

    /// Add a template; a name another template already uses gets " 2", " 3"... so `/name`
    /// stays unambiguous. Returns the stored template.
    @discardableResult
    func add(_ template: TaskTemplate) -> TaskTemplate {
        var t = template
        t.name = uniqueName(t.name, excluding: nil)
        templates.append(t)
        persist()
        return t
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = templates.firstIndex(where: { $0.id == id }),
              templates[i].name != trimmed else { return }
        templates[i].name = uniqueName(trimmed, excluding: id)
        persist()
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        persist()
    }

    /// Import: `replace` swaps the whole list, merge adds templates whose id is new (a re-import
    /// of the same file adds nothing). Returns how many were added.
    @discardableResult
    func importTemplates(_ incoming: [TaskTemplate], replace: Bool) -> Int {
        if replace { templates = [] }
        var added = 0
        for t in incoming where !templates.contains(where: { $0.id == t.id }) {
            var copy = t
            copy.name = uniqueName(copy.name, excluding: nil)
            templates.append(copy)
            added += 1
        }
        persist()
        return added
    }

    /// Snapshot fixtures only (`#if !RELEASE` callers): replaces the in-memory list, no disk.
    func setForSnapshot(_ list: [TaskTemplate]) { templates = list }

    private func uniqueName(_ name: String, excluding id: UUID?) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func taken(_ n: String) -> Bool {
            templates.contains { $0.id != id && KTextFold.fold($0.name) == KTextFold.fold(n) }
        }
        guard taken(base) else { return base }
        var i = 2
        while taken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
