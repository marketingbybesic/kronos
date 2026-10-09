// Live steps for the list view options: the X on a rule chip removes the rule (popover closed and
// open); the sort and filter editors offer only what means something on the list and their X buttons
// work; every offered filter field can be given a value and narrows the list; "Show completed" works in
// every list that holds closed tasks; a list sorted by an attribute puts the tasks without it in their own
// group and can suggest the value. Run alone with `--only group:L-VIEW`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func lViewSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await lViewChipRemove($0) }
        await runStep(model, scope: .all) { await lViewEditors($0) }
        await runStep(model, scope: .all) { await lViewFilterFields($0) }
        await runStep(model, scope: .all) { await lViewPlaceholderRows($0) }
        await runStep(model, scope: .all) { await lViewShowCompleted($0) }
        await runStep(model, scope: .all) { await lViewMissingGroup($0) }
    }

    // MARK: Helpers

    static var lViewBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    static func lViewRendered(_ titles: [String]) -> [String] {
        titles.compactMap { t in UITestAnchors.frames["row." + t].map { (t, $0.minY) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    static func lViewWaitRows(_ titles: [String]) async {
        await waitUntil(timeout: 4) { titles.allSatisfy { UITestAnchors.frames["row." + $0] != nil } }
    }

    /// Waits until exactly `titles` (of `among`) are drawn, in any order.
    @discardableResult
    static func lViewWaitShown(_ titles: [String], among: [String]) async -> Bool {
        let want = Set(titles)
        let ok = await waitUntil(timeout: 4) { Set(lViewRendered(among)) == want }
        await settle(200)
        return ok
    }

    /// Titles of the rows the list model holds (what the screen draws, whether or not it is scrolled to).
    static func lViewRows(_ model: AppModel, among titles: [String]) -> [String] {
        let want = Set(titles)
        return ListContext(model: model).rows.map(\.title).filter { want.contains($0) }
    }

    /// A project of its own, so the list holds exactly the probes. Priorities: low, urgent, medium, high.
    static func lViewProject(_ model: AppModel, _ tag: String) -> (project: KProject, tasks: [KTask]) {
        let store = model.store
        let project = store.createProject(name: "lview.\(tag)")
        var tasks: [KTask] = []
        for (i, p) in [KPriority.low, .urgent, .medium, .high].enumerated() {
            let t = store.create(title: "lview.\(tag).M\(i + 1)", project: project)
            store.setPriority(t.id, p)
            tasks.append(t)
        }
        model.didMutate()
        return (project, tasks)
    }

    static func lViewOpen(_ model: AppModel, _ scope: ListScope, _ titles: [String]) async {
        model.setOptions(.default, for: scope)
        model.scope = scope
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        await lViewWaitRows(titles)
        await settle(300)
    }

    /// A task triage must leave alone (every field locked), so a probe keeps exactly the values set here.
    static func lViewLock(_ model: AppModel, _ id: UUID) {
        model.store.updateNoUndo(id) { $0.lockedFieldsRaw = TriageFieldKind.encode(TriageFieldKind.allCases); $0.needsTriage = false }
    }

    // MARK: The view-options popover (its own window)

    static func lViewPopoverWindow() -> NSWindow? {
        NSApp.windows.first { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
    }

    static func lViewOpenPopover(waitFor anchor: String) async -> Bool {
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let up = await waitUntil(timeout: 4) { UITestAnchors.frames[anchor] != nil && lViewPopoverWindow() != nil }
        await settle(300)
        return up
    }

    /// Runs `body` with the popover's window as the test window (clicks and keys go to it), then restores.
    static func lViewInPopover(_ body: () async -> Bool) async -> Bool {
        guard let main = window, let pop = lViewPopoverWindow() else { return false }
        window = pop
        defer { window = main }
        return await body()
    }

    static func lViewClickPopover(_ id: String, xFraction: CGFloat = 0.5) async -> Bool {
        await lViewInPopover { await click(id, xFraction: xFraction) }
    }

    static func lViewClosePopover() async {
        key("\u{1b}", keyCode: 53)
        let closed = await waitUntil(timeout: 2) { lViewPopoverWindow() == nil }
        if !closed {
            // Esc did not reach it from the main window: press it in the popover's own window.
            _ = await lViewInPopover { key("\u{1b}", keyCode: 53); return true }
            await waitUntil(timeout: 2) { lViewPopoverWindow() == nil }
        }
        await settle(200)
    }
}
#endif
