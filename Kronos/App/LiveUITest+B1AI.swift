// Live steps for the AI wiring. Run alone with `--only group:B1-AI`.
//  1. The AI preferences are read from the hermetic defaults, never from the person's domain.
//  2. The router is rebuilt for an AI key or a rule change and for nothing else.
//  3. R in the Sort card sends nothing when the router is in Off mode, and does when it is not.
//  4. House rules: the list shows an agent's rule switched off, the switch turns it on and off
//     again (the router follows), a second press deletes, hit targets are at least 24 pt.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

/// A borderless window that can take key focus: no title bar, so anchor frames and window
/// coordinates agree, and presses reach the controls.
private final class AIKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
extension LiveUITest {

    private static let aiModeKey = "kronos.ai.mode"
    private static let aiModelKey = "kronos.ai.model"

    private static let aiTriageReply = """
    {"project":null,"priority":2,"due":null,"depth":"shallow","estimateMinutes":15,
     "energyKind":"admin","firstMove":"Open the invoice folder and find September.","labels":[],
     "rationale":"One document and one email, no preparation needed."}
    """

    static func b1AISteps(_ model: AppModel) async {
        let priorAI = model.ai
        let priorMode = KronosEnv.defaults.object(forKey: aiModeKey)
        let priorModel = KronosEnv.defaults.object(forKey: aiModelKey)
        defer {
            if let priorMode { KronosEnv.defaults.set(priorMode, forKey: aiModeKey) } else { KronosEnv.defaults.removeObject(forKey: aiModeKey) }
            if let priorModel { KronosEnv.defaults.set(priorModel, forKey: aiModelKey) } else { KronosEnv.defaults.removeObject(forKey: aiModelKey) }
            AIWiring.stopObserving()
            model.ai = priorAI
        }
        await aiDefaultsAreHermetic(model)
        await aiRouterRebuildsOnlyOnAIKeys(model)
        await aiRefreshWithRouterOff(model)
        await aiHouseRulesList(model)
    }

    // MARK: 1. hermetic defaults

    private static func aiDefaultsAreHermetic(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        KronosEnv.defaults.set("off", forKey: aiModeKey)
        AIWiring.configure(model)
        let offFromHermetic = model.ai == nil
        // Break: expect the router to exist, which the hermetic "off" makes impossible.
        record("the AI mode is read from the hermetic defaults (off there means no router)",
               offFromHermetic != breakMode, "ai=\(model.ai == nil ? "nil" : "router") hermetic=\(KronosEnv.isHermetic)")
        KronosEnv.defaults.removeObject(forKey: aiModeKey)
        AIWiring.configure(model)
        record("with no stored mode the router is built from the defaults of the test",
               model.ai != nil, "ai=\(model.ai == nil ? "nil" : "router")")
    }

    // MARK: 2. rebuild only on AI keys

    private static func aiRouterRebuildsOnlyOnAIKeys(_ model: AppModel) async {
        AIWiring.configure(model)
        let start = AIWiring.rebuildCount
        AIWiring.refresh(model)
        record("refresh with nothing changed keeps the router", AIWiring.rebuildCount == start,
               "count \(start)->\(AIWiring.rebuildCount)")

        AIWiring.observe(model)
        KronosEnv.defaults.set(Date().timeIntervalSince1970, forKey: "kronos.livetest.unrelated")
        await settle(500)
        record("an unrelated preference does not rebuild the router", AIWiring.rebuildCount == start,
               "count \(start)->\(AIWiring.rebuildCount)")
        KronosEnv.defaults.removeObject(forKey: "kronos.livetest.unrelated")

        KronosEnv.defaults.set("test-model-2", forKey: aiModelKey)
        let rebuilt = await waitUntil(timeout: 3) { AIWiring.rebuildCount == start + 1 }
        let candidates = (model.ai as? AIRouter)?.candidates.map { $0.client.modelID } ?? []
        record("changing the AI model rebuilds the router once, with the new model first",
               rebuilt && candidates.first == "test-model-2", "count \(start)->\(AIWiring.rebuildCount) models=\(candidates)")
        AIWiring.stopObserving()
        KronosEnv.defaults.removeObject(forKey: aiModelKey)
        AIWiring.configure(model)
    }

    // MARK: 3. R in the Sort card

    /// A router in Off mode wrapping a counting client: pressing R asks nothing. The same card
    /// with a router that is on asks (the positive control).
    private static func aiRefreshWithRouterOff(_ model: AppModel) async {
        let store = model.store
        let probe = store.create(title: "Refresh probe invoice")
        store.updateNoUndo(probe.id) { $0.needsTriage = true }
        model.didMutate()
        defer { store.softDelete(probe.id); model.didMutate() }

        let script = Array(repeating: FixtureAIClient.Outcome.content(aiTriageReply), count: 8)
        func open(_ router: AIRouter) async {
            model.ai = router
            TriageLaunch.shared.request(.sort)
            model.isTriageOpen = true
            _ = await waitUntil(timeout: 4) { UITestAnchors.frames["triage.card.progress"] != nil }
            await settle(700)
        }
        func close() async {
            key("\u{1B}", keyCode: 53)
            _ = await waitUntil { !model.isTriageOpen }
            await settle(200)
        }

        window.makeKeyAndOrderFront(nil)
        let quiet = FixtureAIClient(modelID: "claude-sonnet-5", script: script)
        await open(AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: quiet)]))
        key("r")
        await settle(900)
        let quietCalls = await quiet.callCount
        record("R in the Sort card with AI off sends nothing", quietCalls == 0, "client calls=\(quietCalls)")
        await close()

        let live = FixtureAIClient(modelID: "claude-sonnet-5", script: script)
        await open(AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: live)]))
        let afterOpen = await live.callCount
        key("r")
        let asked = await waitUntilAsync(timeout: 4) { await live.callCount > afterOpen }
        let afterR = await live.callCount
        record("the same card with AI on asks the model on open and again on R",
               afterOpen >= 1 && asked, "calls open=\(afterOpen) afterR=\(afterR)")
        await close()
    }

    private static func waitUntilAsync(timeout: TimeInterval, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    // MARK: 4. House rules

    private static var aiEventNumber = 0

    private static func aiPost(_ type: NSEvent.EventType, at p: NSPoint, in win: NSWindow) {
        aiEventNumber += 1
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: win.windowNumber, context: nil, eventNumber: 90_000 + aiEventNumber,
                                      clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// Presses the middle of an anchored view of a window other than the main one.
    private static func aiPress(_ id: String, in win: NSWindow) async -> Bool {
        if UITestAnchors.frames[id] == nil { _ = await waitUntil(timeout: 2) { UITestAnchors.frames[id] != nil } }
        guard let f = UITestAnchors.frames[id], f.width > 1, let content = win.contentView else { return false }
        let local = content.isFlipped ? NSPoint(x: f.midX, y: f.midY) : NSPoint(x: f.midX, y: content.bounds.height - f.midY)
        let p = content.convert(local, to: nil)
        if !NSApp.isActive { lostFocus = true }
        aiPost(.mouseMoved, at: p, in: win)
        aiPost(.leftMouseDown, at: p, in: win)
        try? await Task.sleep(for: .milliseconds(60))
        aiPost(.leftMouseUp, at: p, in: win)
        await settle(350)
        return true
    }

    private static func aiRouterRules(_ model: AppModel) -> [String] {
        ((model.ai as? AIRouter)?.houseRules ?? []).map(\.text)
    }

    private static func aiHouseRulesList(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        let agentText = "Calls to the bank are people work."
        let ownText = "Keep first moves under sixty characters."
        let agent = store.addAgentRule(text: agentText, scope: .triage)
        let own = store.addRule(text: ownText, scope: .all, source: .manual)
        model.didMutate()
        AIWiring.configure(model)
        let ids = [agent.id, own.id]
        defer {
            for id in ids { store.deleteRule(id) }
            model.didMutate()
            AIWiring.configure(model)
        }
        record("before the list opens the router carries only the active rule",
               aiRouterRules(model) == [ownText], "rules=\(aiRouterRules(model))")

        let host = NSHostingController(rootView: ScrollView {
            SettingsHouseRulesSection(model: model).padding(Space.x4)
        }.frame(width: 720, height: 520).background(Tok.bg))
        let win = AIKeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentViewController = host
        win.setContentSize(NSSize(width: 720, height: 520))
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        defer { win.orderOut(nil); window.makeKeyAndOrderFront(nil) }
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["houserules.toggle.0"] != nil && UITestAnchors.frames["houserules.toggle.1"] != nil }
        await settle(300)
        record("the House rules list shows both rules", shown, "toggle0=\(UITestAnchors.frames["houserules.toggle.0"] != nil) toggle1=\(UITestAnchors.frames["houserules.toggle.1"] != nil)")

        // Hit targets of the controls.
        var small: [String] = []
        for i in 0..<2 {
            for kind in ["toggle", "delete"] {
                let id = "houserules.\(kind).\(i)"
                if let f = UITestAnchors.frames[id], f.width >= Metrics.minHit, f.height >= Metrics.minHit { continue }
                small.append(id)
            }
        }
        record("every switch and Delete is at least 24 x 24 pt", small.isEmpty, "small=\(small)")

        func isActive(_ id: UUID) -> Bool? { store.allRules(includeInactive: true).first { $0.id == id }?.isActive }

        // The agent's rule starts switched off; the switch turns it on and the router follows.
        record("the agent's rule starts switched off", isActive(agent.id) == false, "active=\(String(describing: isActive(agent.id)))")
        let pressedOn = await aiPress("houserules.toggle.0", in: win)
        record("pressing the switch turns the agent's rule on and the router carries it",
               pressedOn && isActive(agent.id) == true && Set(aiRouterRules(model)) == [agentText, ownText],
               "pressed=\(pressedOn) active=\(String(describing: isActive(agent.id))) rules=\(aiRouterRules(model))")
        let pressedOff = await aiPress("houserules.toggle.0", in: win)
        record("pressing it again turns the rule off and the router drops it",
               pressedOff && isActive(agent.id) == false && aiRouterRules(model) == [ownText],
               "pressed=\(pressedOff) active=\(String(describing: isActive(agent.id))) rules=\(aiRouterRules(model))")

        // The person's own rule round-trips too.
        _ = await aiPress("houserules.toggle.1", in: win)
        let ownOff = isActive(own.id) == false && aiRouterRules(model).isEmpty
        _ = await aiPress("houserules.toggle.1", in: win)
        let ownOn = isActive(own.id) == true && aiRouterRules(model) == [ownText]
        record("the owner's rule switches off and on, the router following each time", ownOff && ownOn,
               "off=\(ownOff) on=\(ownOn)")

        // Delete asks twice.
        _ = await aiPress("houserules.delete.0", in: win)
        let stillThere = store.allRules(includeInactive: true).contains { $0.id == agent.id }
        _ = await aiPress("houserules.delete.0", in: win)
        let gone = !store.allRules(includeInactive: true).contains { $0.id == agent.id }
        let ruleCount = store.allRules(includeInactive: true).filter { ids.contains($0.id) }.count
        // Break: claim two rules are left, which is false after the delete.
        let wantCount = breakMode ? 2 : 1
        record("Delete needs a second press and then removes only that rule",
               stillThere && gone && ruleCount == wantCount, "afterFirst=\(stillThere) afterSecond=\(gone) left=\(ruleCount)")
    }
}
#endif
