// Kronos/App/LiveUITest+AAI.swift — live steps for auto-triage:
//  A. a task written the way MCP writes one (no undo, triage flag cleared) is left with nothing
//     filled and the undo depth does not move;
//  B. the same with the triage flag kept: it is filled, still without an undo step;
//  C. a task the person creates is filled from agreeing neighbours (priority, effort), and the
//     fields the vote did not decide (depth, estimate, energy kind) stay empty;
//  D. title edit, then Discard (pressed on the top edge of the button, outside the glyphs):
//     the title stays, the filled fields are empty again, the "Filled" line is gone.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {

    private static func aiWait(_ ms: Int = 4000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < ms {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
            waited += 100
        }
        return condition()
    }

    /// Presses the anchored view 3 pt below its top edge: inside the frame, outside the label's
    /// glyph rows, so it only lands when the whole frame is pressable.
    private static func aiClickTopEdge(_ id: String) async -> Bool {
        guard let f = UITestAnchors.frames[id], f.height > 8, let content = window.contentView else { return false }
        let x = f.midX
        let local = content.isFlipped ? NSPoint(x: x, y: f.minY + 3) : NSPoint(x: x, y: content.bounds.height - f.minY - 3)
        await clickPoint(content.convert(local, to: nil))
        return true
    }

    static func aAISteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        // The live test launch returns before the app starts its own service: run one here, the
        // same class the app runs, and take it down again afterwards.
        let triage = AutoTriage(model: model)
        triage.start()
        defer { triage.stop() }
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        let priorScope = model.scope
        // Only the neighbour vote is under test: no model may answer (and none may reach the network).
        let priorAI = model.ai
        model.ai = nil
        model.scope = .all
        model.searchText = ""
        model.selectedTaskID = nil
        model.inspectedSubtaskID = nil
        try? await Task.sleep(for: .milliseconds(600))

        // Three neighbours that agree on priority and effort. Their own creation triggers
        // auto-triage, so let that settle, then pin the values the vote must read.
        var made: [UUID] = []
        for word in ["one", "two", "three"] {
            made.append(store.create(title: "Quarterly invoice review \(word)").id)
        }
        try? await Task.sleep(for: .milliseconds(1500))
        for id in made { store.update(id) { $0.priorityRaw = KPriority.high.rawValue; $0.effortRaw = KEffort.s.rawValue } }
        model.didMutate()
        defer {
            for id in made { store.softDelete(id) }
            model.selectedTaskID = nil
            model.scope = priorScope
            model.ai = priorAI
            model.didMutate()
        }

        // C. the person's own creation is filled from the vote.
        let owner = store.create(title: "Quarterly invoice review owner")
        made.append(owner.id)
        let filledOwner = await aiWait { triage.lastFill[owner.id] != nil }
        let o = store.task(owner.id)
        record("auto-triage fills an owner-created task from agreeing neighbours (priority and effort only)",
               filledOwner && o?.priority == .high && o?.effort == .s
                 && o?.depth == .unknown && o?.estimateMinutes == nil && o?.energyKind == nil,
               "filled=\(filledOwner) priority=\(String(describing: o?.priority)) effort=\(String(describing: o?.effort)) depth=\(String(describing: o?.depth)) estimate=\(String(describing: o?.estimateMinutes)) energy=\(String(describing: o?.energyKind))")

        // D. title edit, then Discard.
        let editedTitle = "Quarterly invoice review owner edited"
        store.update(owner.id) { $0.title = editedTitle }
        model.didMutate()
        model.selectedTaskID = owner.id
        let shown = await aiWait { UITestAnchors.frames["inspector.triage.discard"] != nil }
        record("the inspector shows the Filled line with a Discard button", shown, "anchor=\(shown)")
        // The inspector may still be laying out when the anchor first appears: click its settled frame.
        try? await Task.sleep(for: .milliseconds(500))
        let pressed = await aiClickTopEdge("inspector.triage.discard")
        let reverted = await aiWait { store.task(owner.id)?.priority == KPriority.none }
        let after = store.task(owner.id)
        let expectedTitle = breakMode ? "WRONG" : editedTitle
        record("Discard reverts exactly the filled fields and keeps the later title edit",
               pressed && reverted && after?.title == expectedTitle && after?.effort == KEffort.none
                 && triage.lastFill[owner.id] == nil && after?.triageFilledFieldsRaw == "" && after?.triageModel == nil,
               "pressed=\(pressed) reverted=\(reverted) title=\(String(describing: after?.title)) effort=\(String(describing: after?.effort)) fillCleared=\(triage.lastFill[owner.id] == nil) raw=\(String(describing: after?.triageFilledFieldsRaw))")
        let gone = await aiWait { UITestAnchors.frames["inspector.triage.discard"] == nil }
        record("the Filled line is gone after Discard", gone, "anchorGone=\(gone)")
        model.selectedTaskID = nil

        // B. machine-written, triage kept: filled, no undo step.
        let depthB = store.undoDepth
        let withTriage = store.createNoUndo(title: "Quarterly invoice review agent kept")
        store.updateNoUndo(withTriage.id) { $0.source = "mcp"; $0.needsTriage = true }
        made.append(withTriage.id)
        let filledB = await aiWait { store.task(withTriage.id)?.priority == KPriority.high }
        record("a machine-written task that keeps the triage flag is filled without an undo step",
               filledB && store.undoDepth == depthB,
               "filled=\(filledB) depth \(depthB)->\(store.undoDepth)")

        // A. machine-written, triage cleared: untouched.
        let depthA = store.undoDepth
        let noTriage = store.createNoUndo(title: "Quarterly invoice review agent plain")
        store.updateNoUndo(noTriage.id) { $0.source = "mcp"; $0.needsTriage = false }
        made.append(noTriage.id)
        try? await Task.sleep(for: .milliseconds(2500))
        let n = store.task(noTriage.id)
        record("a machine-written task with the triage flag cleared is left untouched",
               n?.priority == KPriority.none && n?.effort == KEffort.none && n?.firstMove == nil
                 && n?.depth == KDepth.unknown && triage.lastFill[noTriage.id] == nil && store.undoDepth == depthA,
               "priority=\(String(describing: n?.priority)) effort=\(String(describing: n?.effort)) firstMove=\(String(describing: n?.firstMove)) depth \(depthA)->\(store.undoDepth)")
    }
}
#endif
