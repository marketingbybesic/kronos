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
            add(title: title, notes: notes, project: project, due: due, model: model)
        case .open(let id):
            guard model.store.task(id) != nil else { return }
            model.scope = .all
            model.selectedTaskID = id
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
