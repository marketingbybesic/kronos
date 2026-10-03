// Kronos/App/URLSchemeRouter.swift
// Runs a parsed `kronos://` action (parser: URLScheme.swift) and the two other "text from outside"
// entry points (Services). Everything goes through the paths the UI already uses: QuickAddCreate for
// adds (one undo step, auto-triage fires), the Spotlight open path for `open`, model.openCapture for Capture.
import AppKit
import KronosCore

@MainActor
enum URLSchemeRouter {
    /// A cold launch delivers the URL before the window exists: hold it until the first frame.
    private static var pending: [URL] = []
    private static var ready = false
    private static var lastHandled: (url: String, at: Date)?
    /// Opens an `x-success` URL. A seam so a test can record the call instead of launching another app.
    static var openCallback: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Called from the first-frame hook in AppDelegate.
    static func markReady(model: AppModel) {
        ready = true
        let queued = pending
        pending = []
        queued.forEach { handle($0, model: model) }
    }

    static func handle(_ url: URL, model: AppModel) {
        guard AppDelegate.shared?.launchFailure == nil else { return }
        guard ready else { pending.append(url); return }
        // AppKit's application(_:open:) and the Apple Event handler can both deliver one URL.
        let key = url.absoluteString
        if let last = lastHandled, last.url == key, Date().timeIntervalSince(last.at) < 1.0 { return }
        lastHandled = (key, Date())
        guard let action = KronosURLParser.parse(url) else { return }
        switch action {
        case let .add(title, notes, project, due):
            let made = add(title: title, notes: notes, project: project, due: due, model: model)
            if let first = made.first { succeed(url, id: first.id, title: first.title) }
        case .open(let id):
            guard model.openTaskByID(id) else { return }
            AppDelegate.shared.bringForward()
            succeed(url, id: id, title: model.store.task(id)?.title)
        case .complete(let id):
            complete(id, model: model)
            if let task = model.store.task(id) { succeed(url, id: id, title: task.title) }
        case .search(let query):
            model.scope = .all
            model.searchText = query
            AppDelegate.shared.bringForward()
        case .scope(let target):
            guard let resolved = listScope(target, store: model.store) else { return }
            model.scope = resolved
            AppDelegate.shared.bringForward()
        case .quickAdd:
            NotificationCenter.default.post(name: .kronosQuickAddPanelRequested, object: nil)
        case .capture(let text):
            model.openCapture(with: text)
            AppDelegate.shared.bringForward()
        case .impuls:
            model.isImpulsOpen = true
            AppDelegate.shared.bringForward()
        }
    }

    /// Title goes through QuickAddCreate, so `#project`, `!`, dates and `a > b` subtasks work in a URL
    /// exactly as in the panel. Explicit `project=` / `due=` fill only what the title did not say.
    @discardableResult
    static func add(title: String, notes: String?, project: String?, due: KronosURLDue?,
                    model: AppModel) -> [KTask] {
        let store = model.store
        var made: [KTask] = []
        store.groupedUndo(String(localized: "undo.quickadd")) {
            made = QuickAddCreate.create(from: title, model: model)
            guard let task = made.first else { return }
            if let notes { store.update(task.id) { $0.notes = notes } }
            if let project, task.project == nil {
                let folded = KTextFold.fold(project)
                if let match = store.allProjects().first(where: { KTextFold.fold($0.name) == folded }) {
                    store.update(task.id) { $0.project = match }
                }
            }
            if let day = dayNumber(due) {
                store.update(task.id) { t in
                    t.dueDay = day
                    // A dated task is a to-do, not Someday (same rule as QuickAddCreate's defaults).
                    if t.status == .someday { t.status = .todo }
                }
            }
        }
        guard let first = made.first else { return [] }
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "app.url.added"), first.title))
        return made
    }

    /// Completes an open task through the store (one undo step, the completion sound and a recurring
    /// task's next instance exactly as in the list). An unknown or already finished task changes nothing.
    @discardableResult
    static func complete(_ id: UUID, model: AppModel) -> Bool {
        guard let task = model.store.task(id), task.deletedAt == nil, KStatus.open.contains(task.status) else { return false }
        model.store.complete(id)
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "app.url.completed"), task.title))
        return true
    }

    /// The list a `kronos://scope` URL names. A project is matched by folded name, exact first, then by prefix.
    static func listScope(_ target: KronosURLScope, store: some TaskStoring) -> ListScope? {
        switch target {
        case .inbox: return .inbox
        case .today: return .today
        case .next7: return .next7
        case .waiting: return .waiting
        case .someday: return .someday
        case .all: return .all
        case .project(let name):
            let folded = KTextFold.fold(name)
            let projects = store.allProjects()
            let match = projects.first { KTextFold.fold($0.name) == folded }
                ?? projects.first { KTextFold.fold($0.name).hasPrefix(folded) }
            return match.map { .project($0.id) }
        }
    }

    /// Opens the `x-success` callback of `url` (if it has a valid one) with the task id appended.
    private static func succeed(_ url: URL, id: UUID, title: String?) {
        guard let callback = KronosURLParser.callback(from: url) else { return }
        openCallback(KronosURLParser.successURL(callback: callback, id: id, title: title))
    }

    static func dayNumber(_ due: KronosURLDue?) -> Int? {
        let today = Day.today(calendar: KronosLocale.calendar)
        switch due {
        case nil: return nil
        case .today: return today
        case .tomorrow: return today + 1
        case .iso(let s): return Day.parseISO(s)
        }
    }
}
