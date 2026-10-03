// Kronos/App/LiveUITest+EntryField.swift
// Live steps for the quick add panel's entry field: type `#hit`, take the suggestion with Tab,
// see the pill, remove it with its ✕; Esc closes the list before the panel; Option-Return adds
// and keeps the pills, Command-Return clears them (both stay open); a prefilled destination pill appears when the
// panel opens over a project list and Backspace in an empty field removes it.
// Keys and clicks are synthetic NSEvents posted to the panel's own window (no Accessibility
// permission, nothing outside this process); every assertion reads MODEL state (the store, the
// entry model the controller exposes), never the text a view happens to show.
// Compiled only outside Release, like the rest of the live test.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {

    /// Fixture project name: the entry field's own example in the request ("#hit" finds it).
    private static let entryProjectName = "Hit list"

    private static func entrySettle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private static func entryType(_ text: String) async {
        for ch in text { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        await entrySettle(250)
    }

    private static func entryMainKey(_ main: NSWindow) async {
        for _ in 0..<20 {
            if NSApp.isActive, main.isKeyWindow { return }
            NSApp.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
            await entrySettle(150)
        }
    }

    /// Opens the panel (the same call the global hotkey makes) and points the key/click helpers at it.
    private static func entryOpenPanel(main: NSWindow) async -> (panel: NSPanel, entry: EntryFieldModel)? {
        AppDelegate.shared?.quickAdd.toggle()
        await entrySettle(900)
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0 !== main && $0.canBecomeKey }) as? NSPanel,
              let entry = AppDelegate.shared?.quickAdd.entry else { return nil }
        // Under load the panel can still be ordering in: typing before it is key loses keystrokes.
        for _ in 0..<20 where !(NSApp.isActive && panel.isKeyWindow) {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            await entrySettle(100)
        }
        await entrySettle(200)
        window = panel
        return (panel, entry)
    }

    private static func entryClosePanel(_ panel: NSPanel, main: NSWindow) async {
        if panel.isVisible { AppDelegate.shared?.quickAdd.toggle(); await entrySettle(500) }
        window = main
        await entryMainKey(main)
    }

    private static func entryDestination(_ pills: [EntryPill]) -> String? {
        for p in pills { if case .destination(let d) = p { return d.name } }
        return nil
    }

    static func entryFieldPanelSteps(_ model: AppModel) async {
        let store = model.store
        let main = window!
        let hit = store.allProjects().first { $0.name == entryProjectName } ?? store.createProject(name: entryProjectName)
        model.didMutate()
        model.scope = .inbox
        await entryMainKey(main)

        // 1. Over Inbox the panel opens with no pill; typing `#hit` lists Hit list first.
        guard let (panel, entry) = await entryOpenPanel(main: main) else {
            record("entry: panel opens", false, "no visible key-capable panel or no entry model"); return
        }
        record("entry: panel over Inbox opens with no pill", entry.pills.isEmpty, "pills=\(entry.pills)")
        await entryType("Call mom #hit")
        record("entry: typing #hit opens the suggestion list, Hit list first",
               entry.isListOpen && entry.selected?.title == entryProjectName && UITestAnchors.frames["entry.list"] != nil,
               "open=\(entry.isListOpen) first=\(entry.selected?.title ?? "nil") anchor=\(UITestAnchors.frames["entry.list"] != nil)")

        // 2. Tab takes it: the token leaves the text, a destination pill appears.
        key("\t", keyCode: 48); await entrySettle(400)
        record("entry: Tab turns the token into a pill and clears it from the text",
               entryDestination(entry.pills) == entryProjectName && entry.text == "Call mom" && !entry.isListOpen
                && UITestAnchors.frames["entry.pill.destination"] != nil,
               "pills=\(entry.pills) text=\(entry.text.debugDescription) list=\(entry.isListOpen)")

        // 3. The pill's ✕ removes it and leaves the title alone.
        let clicked = await click("entry.pill.destination.remove")
        await entrySettle(400)
        record("entry: the pill's x removes it", clicked && entry.pills.isEmpty && entry.text == "Call mom",
               "found=\(clicked) pills=\(entry.pills) text=\(entry.text.debugDescription)")

        // 4. Esc closes the list first and the panel only on the second press.
        await entryType(" #hit")
        let listOpen = entry.isListOpen
        key("\u{1B}", keyCode: 53); await entrySettle(400)
        let afterFirst = (listOpen, entry.isListOpen, panel.isVisible)
        key("\u{1B}", keyCode: 53); await entrySettle(700)
        record("entry: Esc closes the suggestion list first, the panel second",
               afterFirst.0 && !afterFirst.1 && afterFirst.2 && !panel.isVisible,
               "listBefore=\(afterFirst.0) listAfterEsc1=\(afterFirst.1) panelAfterEsc1=\(afterFirst.2) panelAfterEsc2=\(panel.isVisible)")
        window = main
        await entryMainKey(main)

        // 5. Option-Return adds and keeps the pills; Command-Return adds, clears them and stays open.
        guard let (panel2, entry2) = await entryOpenPanel(main: main) else {
            record("entry: panel reopens", false, "no panel"); return
        }
        await entryType("#hit")
        key("\t", keyCode: 48); await entrySettle(300)
        await entryType("entryfield first")
        key("\r", modifiers: .option, keyCode: 36); await entrySettle(700)
        let first = store.allTasks().first { $0.title == "entryfield first" }
        let keptAfterFirst = entryDestination(entry2.pills) == entryProjectName && entry2.text.isEmpty
        await entryType("entryfield second")
        key("\r", modifiers: .option, keyCode: 36); await entrySettle(700)
        let second = store.allTasks().first { $0.title == "entryfield second" }
        record("entry: Option-Return adds into the project and keeps the pill (batch)",
               first?.project?.id == hit.id && second?.project?.id == hit.id && keptAfterFirst
                && entryDestination(entry2.pills) == entryProjectName && entry2.text.isEmpty,
               "first=\(first?.project?.name ?? "nil") second=\(second?.project?.name ?? "nil") keptAfterFirst=\(keptAfterFirst) pills=\(entry2.pills)")
        await entryType("entryfield third")
        key("\r", modifiers: .command, keyCode: 36); await entrySettle(700)
        let third = store.allTasks().first { $0.title == "entryfield third" }
        record("entry: Command-Return adds into the project, clears the pills and stays open",
               third?.project?.id == hit.id && entry2.pills.isEmpty && entry2.text.isEmpty && panel2.isVisible,
               "third=\(third?.project?.name ?? "nil") pills=\(entry2.pills) text=\(entry2.text.debugDescription) open=\(panel2.isVisible)")
        await entryClosePanel(panel2, main: main)

        // 6. Over a project list the destination is prefilled; Backspace in an empty field removes it.
        model.scope = .project(hit.id)
        await entryMainKey(main)
        if let (panel3, entry3) = await entryOpenPanel(main: main) {
            let prefilled = entryDestination(entry3.pills) == entryProjectName && entry3.pills.count == 1
            await entryType("entryfield from list")
            key("\r", keyCode: 36); await entrySettle(700)
            let fromList = store.allTasks().first { $0.title == "entryfield from list" }
            record("entry: panel over a project list starts with that project as a pill and files into it",
                   prefilled && fromList?.project?.id == hit.id,
                   "prefilled=\(prefilled) project=\(fromList?.project?.name ?? "nil")")
            await entryClosePanel(panel3, main: main)
            await entryMainKey(main)
            if let (panel4, entry4) = await entryOpenPanel(main: main) {
                let before = entry4.pills.count
                key("\u{7F}", keyCode: 51); await entrySettle(400)
                record("entry: Backspace in an empty field removes the last pill",
                       before == 1 && entry4.pills.isEmpty, "before=\(before) after=\(entry4.pills.count)")
                await entryClosePanel(panel4, main: main)
            } else {
                record("entry: panel reopens over the project list", false, "no panel")
            }
        } else {
            record("entry: panel opens over a project list", false, "no panel")
        }

        // 7. Back on Inbox the pill is gone again.
        model.scope = .inbox
        await entryMainKey(main)
        if let (panel5, entry5) = await entryOpenPanel(main: main) {
            record("entry: back on Inbox the panel opens with no pill", entry5.pills.isEmpty, "pills=\(entry5.pills)")
            await entryClosePanel(panel5, main: main)
        } else {
            record("entry: panel opens over Inbox again", false, "no panel")
        }

        for t in store.allTasks() where t.title.hasPrefix("entryfield ") { store.softDelete(t.id) }
        model.didMutate()
        window = main
        await entryMainKey(main)
    }
}
#endif
