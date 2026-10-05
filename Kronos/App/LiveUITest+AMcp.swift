// Live steps for agents over MCP. Run alone with `--only group:A-MCP2`.
//  1. Settings > Agents renders: the rail row opens a pane with its intro and the add row (the pane
//     used to stay blank for good because its controller was created from an empty view).
//  2. Full control is off for a new agent, turning it on asks first, and the choice lands in the
//     agent store (write.all); turning it off is immediate.
//  3. The inspector's review section: Reject and Accept, each with a comment typed into the real
//     field, write the person's verdict on the task, and the agent reads verdict and comment through
//     get_task and events_poll.
#if !RELEASE
import AppKit
import SwiftUI
import SwiftData
import KronosCore

/// A borderless window that can take key focus, so presses and keys reach the hosted controls.
private final class AMcpKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
extension LiveUITest {

    static func aMcpSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        await aMcpSettings(model, breakMode: breakMode)
        await aMcpInspectorVerdicts(model, breakMode: breakMode)
    }

    // MARK: 1 + 2. Settings > Agents

    private static func aMcpScopes(_ slug: String) -> AgentScopes? {
        // A fresh handle each time, so a row another handle saved is read from disk, never from a cache.
        guard let hub = try? AgentHub(directory: KronosStore.containerDirectory(), tokenFiles: nil) else { return nil }
        return hub.agent(slug: slug).map { AgentScopes(csv: $0.scopesRaw) }
    }

    private static func aMcpSettings(_ model: AppModel, breakMode: Bool) async {
        let main: NSWindow = window
        let win = AMcpKeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentViewController = NSHostingController(rootView:
            SettingsScreen(model: model, initialTab: .general).frame(width: 900, height: 1100).background(Tok.bg))
        win.setContentSize(NSSize(width: 900, height: 1100))
        win.center()
        window = win
        defer {
            win.orderOut(nil)
            window = main
            main.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 5) { UITestAnchors.frames["settings.rail.agents"] != nil }
        await settle(400)

        // The pane renders (an empty store: the intro and the add row, no agent yet).
        _ = await click("settings.rail.agents")
        let up = await waitUntil(timeout: 5) { UITestAnchors.frames["settings.agents.intro"] != nil }
        await settle(300)
        let intro = UITestAnchors.frames["settings.agents.intro"]
        let add = UITestAnchors.frames["settings.agents.add"]
        // Break: ask for the pane to be blank, which it no longer is.
        let rendered = up && (intro?.width ?? 0) > 300 && (intro?.height ?? 0) > 10 && (add?.width ?? 0) > 20
        record("Settings > Agents renders its intro and its add row (it used to stay blank)",
               breakMode ? intro == nil : rendered,
               "intro=\(intro.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil") add=\(add.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")

        // Full control.
        _ = await click("settings.rail.general")
        await settle(300)
        guard let seed = try? AgentHub(directory: KronosStore.containerDirectory(), tokenFiles: nil),
              let made = seed.addAgent(displayName: "Live Probe") else {
            record("Full control: a new agent starts without it, asks before it is given, and lands in the agent store", false, "no scratch agent")
            return
        }
        let slug = made.agent.slug
        defer { (try? AgentHub(directory: KronosStore.containerDirectory(), tokenFiles: nil))?.remove(slug: slug) }
        let toggle = "settings.agents.fullcontrol.\(slug)"
        let confirm = "settings.agents.confirm.\(slug)"
        _ = await click("settings.rail.agents")
        let listed = await waitUntil(timeout: 5) { UITestAnchors.frames[toggle] != nil }
        await settle(300)
        let startsOff = aMcpScopes(slug)?.has(.writeAll) == false
        _ = await click(toggle)
        var asked = await waitUntil(timeout: 3) { UITestAnchors.frames[confirm] != nil }
        if !asked {   // a first press can be spent on focusing the window; press once more
            _ = await click(toggle)
            asked = await waitUntil(timeout: 3) { UITestAnchors.frames[confirm] != nil }
        }
        let stillOff = aMcpScopes(slug)?.has(.writeAll) == false
        _ = await click(confirm)
        let granted = await waitUntil(timeout: 3) { aMcpScopes(slug)?.has(.writeAll) == true }
        let keeps = aMcpScopes(slug).map { $0.has(.read) && $0.has(.propose) && $0.has(.writeOwn) && $0.has(.comment) } ?? false
        await settle(300)
        _ = await click(toggle)
        var revoked = await waitUntil(timeout: 3) { aMcpScopes(slug)?.has(.writeAll) == false }
        if !revoked {
            _ = await click(toggle)
            revoked = await waitUntil(timeout: 3) { aMcpScopes(slug)?.has(.writeAll) == false }
        }
        // Break: expect the grant to have happened without being asked.
        record("Full control: a new agent starts without it, asks before it is given, keeps its other rights, and turning it off is immediate",
               listed && startsOff && asked && stillOff && (breakMode ? !asked : granted) && keeps && revoked,
               "listed=\(listed) startsOff=\(startsOff) asked=\(asked) stillOff=\(stillOff) granted=\(granted) keeps=\(keeps) revoked=\(revoked)")
    }

    // MARK: 3. Inspector review section

    private static func aMcpCall(_ d: MCPDispatcher, _ me: AgentIdentity, _ tool: String, _ args: [String: Any]) -> [String: Any] {
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": tool, "arguments": args] as [String: Any]]
        guard let body = try? JSONSerialization.data(withJSONObject: rpc),
              let data = d.handleBody(body, agent: me).body,
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let res = top["result"] as? [String: Any] else { return [:] }
        return res["structuredContent"] as? [String: Any] ?? [:]
    }

    /// Selects the task, opens the inspector's Details when the review section is not yet on screen.
    private static func aMcpOpenReview(_ model: AppModel, _ id: UUID) async -> Bool {
        model.selectedTaskID = id
        await settle(800)
        if UITestAnchors.frames["inspector.review.accept"] == nil {
            _ = await click("inspector.details.toggle")
            await settle(500)
        }
        return await waitUntil(timeout: 4) { UITestAnchors.frames["inspector.review.accept"] != nil }
    }

    private static func aMcpInspectorVerdicts(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        window.makeKeyAndOrderFront(nil)
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        await settle(600)
        guard let container = try? KronosLocalStore.makeContainer(inMemory: true) else {
            record("inspector review section: Reject and Accept write the verdict and the agent reads it", false, "no scratch agent store")
            return
        }
        let hub = AgentHub(context: ModelContext(container), tokenFiles: nil)
        let agent = hub.register(slug: "amcp-agent")
        guard let me = hub.identity(slug: "amcp-agent") else { return }
        let dispatcher = MCPDispatcher(store: store, ranking: RankingEngine())
        dispatcher.hub = hub

        func awaiting(_ title: String) -> KTask {
            let t = ReviewSnapshots.proposal(store, title: title, review: ReviewState.awaitingCheck, context: [:],
                                             result: ["note": "Written and saved."], assignee: 1)
            store.updateNoUndo(t.id) { $0.agentID = agent.id }
            hub.append(actor: "agent:amcp-agent", verb: ActivityVerb.doneByAgent, taskID: t.id, agentID: agent.id)
            return t
        }
        let rejected = awaiting("amcp.verdict.reject")
        let accepted = awaiting("amcp.verdict.accept")
        model.didMutate()
        model.scope = .all
        model.searchText = ""
        model.inspectedSubtaskID = nil
        await settle(500)
        let detailsWasOpen = UserDefaults.standard.bool(forKey: "kronos.inspector.detailsOpen")
        defer {
            if !detailsWasOpen, UITestAnchors.frames["inspector.details.toggle"] != nil {
                Task { @MainActor in _ = await click("inspector.details.toggle") }
            }
            for id in [rejected.id, accepted.id] { store.softDelete(id) }
            model.selectedTaskID = nil
            model.didMutate()
        }

        // Reject, with a comment typed into the real field.
        let shownA = await aMcpOpenReview(model, rejected.id)
        let hasComment = UITestAnchors.frames["inspector.review.comment"] != nil
        let hasReject = UITestAnchors.frames["inspector.review.reject"] != nil
        let big = (UITestAnchors.frames["inspector.review.accept"]?.height ?? 0) >= Metrics.minHit - 4
        _ = await click("inspector.review.comment")
        await settle(300)
        await typeText("needs the link")
        let typed = rejected.id
        _ = await click("inspector.review.reject")
        _ = await waitUntil(timeout: 4) { store.task(typed)?.reviewRaw == ReviewState.none }
        await settle(300)
        let rt = store.task(rejected.id)
        let rResult = AgentTaskResult.decode(rt?.resultJSON)
        let wantComment = breakMode ? "something nobody typed" : "needs the link"
        let rejectedOK = rt?.reviewRaw == ReviewState.none && rt?.status != .done
            && rResult?.verdict == "rejected" && rResult?.verdictComment?.contains(wantComment) == true
        let viaGet = aMcpCall(dispatcher, me, "get_task", ["id": rejected.id.uuidString])
        let gv = (viaGet["task"] as? [String: Any])?["verdict"] as? [String: Any]
        let events = aMcpCall(dispatcher, me, "events_poll", [:])["events"] as? [[String: Any]] ?? []
        let back = events.first { $0["kind"] as? String == ActivityVerb.reopened && ($0["task"] as? [String: Any])?["id"] as? String == rejected.id.uuidString }
        let br = back?["result"] as? [String: Any]
        record("inspector review: Reject with a typed comment sends the task back, and the agent reads verdict and comment in get_task and events_poll",
               shownA && hasComment && hasReject && big && rejectedOK
                   && gv?["decision"] as? String == "rejected" && (gv?["comment"] as? String)?.contains(wantComment) == true
                   && br?["verdict"] as? String == "rejected" && (br?["comment"] as? String)?.contains(wantComment) == true,
               "shown=\(shownA) comment=\(hasComment) reject=\(hasReject) big=\(big) review=\(String(describing: rt?.reviewRaw)) verdict=\(String(describing: rResult?.verdict)) comment=\(String(describing: rResult?.verdictComment)) get=\(String(describing: gv)) event=\(String(describing: br))")

        // Accept, with a comment.
        let shownB = await aMcpOpenReview(model, accepted.id)
        _ = await click("inspector.review.comment")
        await settle(300)
        await typeText("ship it")
        _ = await click("inspector.review.accept")
        _ = await waitUntil(timeout: 4) { store.task(accepted.id)?.status == .done }
        await settle(300)
        let at = store.task(accepted.id)
        let aResult = AgentTaskResult.decode(at?.resultJSON)
        let wantAccept = breakMode ? "something nobody typed" : "ship it"
        let acceptedOK = at?.status == .done && at?.reviewRaw == ReviewState.approved
            && aResult?.verdict == "accepted" && aResult?.verdictComment?.contains(wantAccept) == true
        let viaGet2 = aMcpCall(dispatcher, me, "get_task", ["id": accepted.id.uuidString])
        let gv2 = (viaGet2["task"] as? [String: Any])?["verdict"] as? [String: Any]
        let events2 = aMcpCall(dispatcher, me, "events_poll", [:])["events"] as? [[String: Any]] ?? []
        let done = events2.first { $0["kind"] as? String == ActivityVerb.completed && ($0["task"] as? [String: Any])?["id"] as? String == accepted.id.uuidString }
        let dr = done?["result"] as? [String: Any]
        record("inspector review: Accept with a typed comment closes the task, and the agent reads verdict and comment in get_task and events_poll",
               shownB && acceptedOK && gv2?["decision"] as? String == "accepted" && (gv2?["comment"] as? String)?.contains(wantAccept) == true
                   && dr?["verdict"] as? String == "accepted" && (dr?["comment"] as? String)?.contains(wantAccept) == true,
               "shown=\(shownB) status=\(String(describing: at?.status)) review=\(String(describing: at?.reviewRaw)) verdict=\(String(describing: aResult?.verdict)) comment=\(String(describing: aResult?.verdictComment)) get=\(String(describing: gv2)) event=\(String(describing: dr))")

        // The agent itself cannot pass a review: a status change on a task waiting for the person is refused.
        let guarded = awaiting("amcp.verdict.guard")
        model.didMutate()
        let refused = aMcpCall(dispatcher, me, "update_task", ["id": guarded.id.uuidString, "status": "done"])
        let still = store.task(guarded.id)
        record("an agent cannot close a task that waits for the owner's check",
               refused["error"] as? String == "FORBIDDEN" && still?.reviewRaw == ReviewState.awaitingCheck && still?.status != .done,
               "answer=\(refused["error"] as? String ?? "none") review=\(String(describing: still?.reviewRaw)) status=\(String(describing: still?.status))")
        store.softDelete(guarded.id)
    }
}
#endif
