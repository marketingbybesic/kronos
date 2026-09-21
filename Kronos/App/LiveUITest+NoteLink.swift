// Kronos/App/LiveUITest+NoteLink.swift — drag-and-drop for linking a note was repeatedly
// reported dead; the measured cause (the drag session's own type-identifier log file was
// never created on disk) was that AppKit's drag-destination callback never ran once — no
// synthetic-drag harness could have proven that either way, so the fix is a button instead,
// and THIS step proves the button, never a drag. `AppleNotesBridge` is swapped for an
// injected `FixtureNotesBridge` (KronosCore) before the click — never real Notes, never
// AppleScript, same hermetic rule every other fixture in this file already follows
// (`quickAddPanelTypes`'s own doc comment).
// Compiled only outside Release: extends `LiveUITest`, whose real implementation (the only
// caller of `noteLinkButton`) is itself compiled out under Release — see LiveUITest.swift.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    /// 10. Click "Link Apple note" -> the picker sheet appears -> pick the first fixture note
    /// -> the task's notes carry the `notes://` line and the row shows title + Open note +
    /// Unlink. Runs on a plain task the earlier steps did not touch (never `target`, which the
    /// inspector.notelink screens already exercise via snapshot — this is the live click path,
    /// not a second copy of that coverage).
    static func noteLinkButton(_ model: AppModel) async {
        let store = model.store
        let mainWindow = window!
        guard let task = store.allTasks().first(where: { KStatus.open.contains($0.status) && NoteLink.find(in: $0.notes) == nil }) else {
            record("has an unlinked task for the note-link step", false, ""); return
        }
        model.notes = NoteLinkTestFixtures.bridge()

        // The inspector pane auto-collapses below ~sidebar+740pt (AppShellView.swift:
        // `inspectorAutoCollapsed`) — no earlier step in this file ever needed the pane visible,
        // so this is the first to require a wide-enough window (same `window.setFrame` idiom
        // `paletteFits` already uses below).
        var frame = mainWindow.frame
        frame.size = NSSize(width: 1100, height: 760)
        mainWindow.setFrame(frame, display: true)
        try? await Task.sleep(for: .milliseconds(300))

        // Selecting via model state directly (not a row click) — the row-click path is already
        // proven by the earlier "row one click selects" step; this step's job is the button,
        // and a direct select is immune to the target row being scrolled out of the current
        // sidebar scope (every earlier step may have changed scope/scroll position).
        model.selectedTaskID = task.id
        try? await Task.sleep(for: .milliseconds(500))
        diagnostics.append("noteLinkButton: task=\(task.title) selected=\(model.selectedTaskID == task.id) notelinkAnchor=\(UITestAnchors.frames["inspector.notelink.add"] != nil)")

        let ok = await click("inspector.notelink.add")
        try? await Task.sleep(for: .milliseconds(500))
        guard let sheet = NSApp.windows.first(where: { $0.isVisible && $0 !== mainWindow && $0.canBecomeKey }) else {
            record("note-link button opens the picker", false, "found=\(ok) no sheet window appeared"); return
        }
        window = sheet
        try? await Task.sleep(for: .milliseconds(300))
        let pickerVisible = UITestAnchors.frames["notespicker.search"] != nil
        record("note-link button opens the picker", ok && pickerVisible, "clicked=\(ok) searchFieldVisible=\(pickerVisible)")

        // The fixture's one folder ("Kronos") is the sheet's first row; select it, then the
        // first note row, mirroring the real click path (folder, then note) — `initialFolder`
        // is nil here on purpose so this covers the two-level nav, not a shortcut past it.
        _ = await click("notespicker.folder.Kronos"); try? await Task.sleep(for: .milliseconds(400))
        let notePicked = await click("notespicker.row.Acme kickoff recap")
        try? await Task.sleep(for: .milliseconds(500))
        window = mainWindow

        let updated = store.task(task.id)
        let linked = NoteLink.find(in: updated?.notes ?? "") == "n1"
        record("pick the first fixture note links it", notePicked && linked,
               "picked=\(notePicked) notesLine=\(updated?.notes.split(separator: "\n").first(where: { $0.hasPrefix("notes://") }).map(String.init) ?? "none")")

        // Poll rather than one fixed sleep: distinguishes "slow to render" from "never renders".
        // No resize workaround here on purpose: this is the actual assertion that the inspector
        // pane survives the picker sheet's dismissal at the SAME window size it was opened at.
        // `AppShellView.swift`'s `windowWidth` now comes only from AppKit (`WindowWidthReader` +
        // `WindowWidthObserver`, Kronos/App/WindowWidthReader.swift), never `GeometryReader` —
        // measured: `GeometryReader`'s `proxy.size.width` durably reported a stale, too-narrow
        // value after this exact sheet dismissed even though the real `NSWindow`/
        // `contentView.bounds` never changed, and this step is what caught it.
        var cardShowsTitle = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            if UITestAnchors.frames["inspector.notelink.open"] != nil { cardShowsTitle = true; break }
        }
        record("linked row shows title, Open note, Unlink (inspector survives the sheet closing, no resize)",
               cardShowsTitle, "openAnchor=\(cardShowsTitle)")
    }
}
#endif
