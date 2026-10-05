// Live steps for Capture: the shapes a person types into the paste field, end to end through the
// real screen (paste field -> Cmd-Return -> review -> Cmd-Return -> done) and judged on the tasks
// that land in the scratch store. Run alone with `--only group:I-CAPTURE`. `KRONOS_UITEST_BREAK=1`
// flips one expectation: the run must then fail.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func iCaptureSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard KronosEnv.isHermetic else { record("I-CAPTURE runs only on a scratch store", false, "not hermetic"); return }
        let savedAI = model.ai
        let savedUseAI = CapturePrefs.useAI
        CapturePrefs.useAI = true
        model.ai = nil
        await icPasteStepButtons(model)
        await icPlainLines(model, breakMode: breakMode)
        await icSubtaskForms(model)
        await icNumberedDuplicatesShort(model)
        await icPreviewBeforeCommit(model)
        await icProse(model)
        model.ai = savedAI
        CapturePrefs.useAI = savedUseAI
        model.isCaptureOpen = false
        await settle(300)
    }

    // MARK: Helpers

    private static func icTextView(at anchor: String) -> NSTextView? {
        guard let p = point(anchor), let content = window.contentView else { return nil }
        func walk(_ v: NSView) -> NSTextView? {
            if let tv = v as? NSTextView, !tv.isHidden, tv.convert(tv.bounds, to: nil).contains(p) { return tv }
            for s in v.subviews { if let f = walk(s) { return f } }
            return nil
        }
        return walk(content)
    }

    private static func icOpen(_ model: AppModel) async -> NSTextView? {
        await ensureKey(window)
        model.isCaptureOpen = false
        await settle(300)
        model.isCaptureOpen = true
        await settle(900)
        guard let tv = icTextView(at: "capture.paste") else { return nil }
        tv.window?.makeFirstResponder(tv)
        return tv
    }

    /// A task as it stood right after Create, read BEFORE the scratch cleanup removes it.
    private struct IcMade {
        var title: String
        var isChild: Bool
        var subs: [String]
        var notes: String
    }

    /// Pastes `text`, finds tasks, optionally creates the ticked rows, and returns the tasks that
    /// landed (new ids only) plus whether the review step was reached.
    private static func icRun(_ model: AppModel, _ text: String, create: Bool = true, waitAfterFind: Int = 900)
        async -> (reviewed: Bool, new: [IcMade]) {
        guard let tv = await icOpen(model) else {
            record("capture: paste field found", false, "no text view"); return (false, [])
        }
        tv.selectAll(nil)
        tv.insertText(text, replacementRange: tv.selectedRange())
        await settle(200)
        let before = Set(model.store.allTasks().map(\.id))
        key("\r", modifiers: .command, keyCode: 36)
        await settle(waitAfterFind)
        let reviewed = UITestAnchors.frames["capture.review"] != nil
        if create && reviewed {
            key("\r", modifiers: .command, keyCode: 36)
            await settle(900)
        }
        let landed = model.store.allTasks().filter { !before.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        let new = landed.map { IcMade(title: $0.title, isChild: $0.parentID != nil, subs: $0.orderedSubtasks.map(\.title), notes: $0.notes) }
        if create {
            for t in landed { model.store.softDeleteNoUndo(t.id) }
            model.didMutate()
            model.isCaptureOpen = false
            await settle(300)
        }
        return (reviewed, new)
    }

    private static func icTitles(_ tasks: [IcMade]) -> [String] { tasks.filter { !$0.isChild }.map(\.title) }

    private static func icTask(_ title: String, in tasks: [IcMade]) -> IcMade? { tasks.first { $0.title == title } }

    private static func icSubs(_ t: IcMade?) -> [String] { t?.subs ?? [] }

    private static func icSubsK(_ t: KTask?) -> [String] { t?.orderedSubtasks.map(\.title) ?? [] }

    // MARK: Paste step: only the two sources remain

    private static func icPasteStepButtons(_ model: AppModel) async {
        guard await icOpen(model) != nil else { record("capture: paste step opens", false, "no text view"); return }
        let sources = UITestAnchors.frames.keys.filter { $0.hasPrefix("capture.source.") }.sorted()
        let clip = UITestAnchors.frames["capture.source.clipboard"], notes = UITestAnchors.frames["capture.source.notes"]
        record("capture: the paste step offers exactly the clipboard and Apple Notes sources, side by side",
               sources == ["capture.source.clipboard", "capture.source.notes"] && clip != nil && notes != nil
                   && abs((clip?.midY ?? 0) - (notes?.midY ?? 99)) < 2 && (clip?.maxX ?? 0) <= (notes?.minX ?? 0),
               "anchors=\(sources) clip=\(String(describing: clip)) notes=\(String(describing: notes))")
        record("capture: the paste step shows the one-line grammar hint",
               UITestAnchors.frames["capture.paste.hint"] != nil, "hint anchor=\(UITestAnchors.frames["capture.paste.hint"] != nil)")
        model.isCaptureOpen = false
        await settle(300)
    }

    // MARK: Plain lines, blank lines, lowercase

    private static func icPlainLines(_ model: AppModel, breakMode: Bool) async {
        let a = await icRun(model, "icapA one\nicapA two\nicapA three")
        record("capture: three plain lines are three tasks",
               icTitles(a.new) == ["icapA one", "icapA two", "icapA three"], "titles=\(icTitles(a.new))")
        let b = await icRun(model, "icapB one\n\nicapB two\n\n\nicapB three")
        record("capture: lines separated by one and by two blank lines are separate tasks",
               b.new.count == (breakMode ? 4 : 3) && icTitles(b.new) == ["icapB one", "icapB two", "icapB three"],
               "titles=\(icTitles(b.new))")
        let c = await icRun(model, "icapC kupiti mlijeko\nicapC nazvati mamu.\nicapC poslati racun!")
        record("capture: lowercase and period-ended lines are tasks, never swallowed as notes",
               icTitles(c.new).count == 3 && c.new.allSatisfy { $0.notes.isEmpty },
               "titles=\(icTitles(c.new)) notes=\(c.new.map(\.notes))")
    }

    // MARK: Subtask forms

    private static func icSubtaskForms(_ model: AppModel) async {
        let forms = ["\tc1", "  c2", "    c3", "- c4", "* c5", "• c6", "> c7"]
        let text = forms.enumerated().map { "icapS\($0.offset + 1) parent\n\($0.element)" }.joined(separator: "\n\n")
        let r = await icRun(model, text)
        let parents = r.new.filter { !$0.isChild }
        let ok = parents.count == 7 && (1...7).allSatisfy { i in
            icSubs(icTask("icapS\(i) parent", in: parents)) == ["c\(i)"]
        }
        record("capture: subtasks by tab, 2 spaces, 4 spaces, -, *, bullet dot and > all land under their task",
               ok, "parents=\(parents.map(\.title)) subs=\(parents.map { icSubs($0) })")
    }

    // MARK: Numbered lists, duplicate titles, short titles

    private static func icNumberedDuplicatesShort(_ model: AppModel) async {
        let n = await icRun(model, "1. icapN one\n2. icapN two\n3) icapN three")
        record("capture: a numbered list is a list of tasks", icTitles(n.new) == ["icapN one", "icapN two", "icapN three"],
               "titles=\(icTitles(n.new))")
        let d = await icRun(model, "icapD twin\n- first\n\nicapD twin\n- second")
        let twins = d.new.filter { !$0.isChild && $0.title == "icapD twin" }
        record("capture: two tasks with the same title keep their own subtasks",
               twins.count == 2 && Set(twins.map { icSubs($0) }) == [["first"], ["second"]],
               "subs=\(twins.map { icSubs($0) })")
        let existing = model.store.allTasks().filter { ["Go", "Pay"].contains($0.title) }
        let s = await icRun(model, "Go\nPay")
        record("capture: short titles survive", existing.isEmpty && icTitles(s.new) == ["Go", "Pay"],
               "existing=\(existing.count) titles=\(icTitles(s.new))")
    }

    // MARK: Preview before commit

    private static func icPreviewBeforeCommit(_ model: AppModel) async {
        let text = "icapP plan trip\n- icapP book flights\n- icapP book hotel\n\nicapP pack\n  icapP passport"
        let before = Set(model.store.allTasks().map(\.id))
        let r = await icRun(model, text, create: false)
        let madeEarly = model.store.allTasks().filter { !before.contains($0.id) }
        // Nested: each subtask line is drawn inside the frame of the task row it belongs to.
        func inside(_ sub: String, _ parent: String) -> Bool {
            guard let s = UITestAnchors.frames["capture.review.sub.\(sub)"], let p = UITestAnchors.frames["capture.review.row.\(parent)"] else { return false }
            return p.contains(s)
        }
        let nested = inside("icapP book flights", "icapP plan trip") && inside("icapP book hotel", "icapP plan trip")
            && inside("icapP passport", "icapP pack")
        record("capture: the review step lists the tasks with their subtasks before anything is created",
               r.reviewed && madeEarly.isEmpty && nested,
               "reviewed=\(r.reviewed) createdEarly=\(madeEarly.count) nested=\(nested) anchors=\(UITestAnchors.frames.keys.filter { $0.contains("icapP") }.sorted())")
        key("\r", modifiers: .command, keyCode: 36)
        await settle(900)
        let made = model.store.allTasks().filter { !before.contains($0.id) }
        let parents = made.filter { $0.parentID == nil }
        record("capture: Create commits exactly the previewed structure",
               parents.count == 2 && icSubsK(parents.first { $0.title == "icapP plan trip" }) == ["icapP book flights", "icapP book hotel"]
                   && icSubsK(parents.first { $0.title == "icapP pack" }) == ["icapP passport"],
               "parents=\(parents.map(\.title)) trip=\(icSubsK(parents.first { $0.title == "icapP plan trip" }))")
        for t in made { model.store.softDeleteNoUndo(t.id) }
        model.didMutate()
        model.isCaptureOpen = false
        await settle(300)
    }

    // MARK: Prose: AI path with a fixture client, plain fallback when AI is off

    private static func icProse(_ model: AppModel) async {
        let prose = "Please icapQ call Alex and then icapQ send the contract and also icapQ book the venue for the party"
        let reply = "1. icapQ call Alex !! *\n\n2. icapQ send the contract !! *\n\n3. icapQ book the venue !! *\n"
        let client = FixtureAIClient(modelID: "fixture-capture", script: [.content(reply)])
        model.ai = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        let ai = await icRun(model, prose, waitAfterFind: 1800)
        record("capture: a prose paragraph goes through the AI extraction and becomes separate tasks",
               icTitles(ai.new) == ["icapQ call Alex", "icapQ send the contract", "icapQ book the venue"],
               "titles=\(icTitles(ai.new))")

        model.ai = nil
        let off = await icRun(model, "icapR call Alex. He wants the PDF.", create: false)
        let hint = UITestAnchors.frames["capture.status.prose"] != nil
        let before = Set(model.store.allTasks().map(\.id))
        key("\r", modifiers: .command, keyCode: 36)
        await settle(900)
        let made = model.store.allTasks().filter { !before.contains($0.id) }
        record("capture: with AI off the paragraph still becomes a plain-line task and says AI would split it",
               off.reviewed && hint && made.count == 1 && made[0].title.hasPrefix("icapR call Alex"),
               "reviewed=\(off.reviewed) hint=\(hint) made=\(made.map(\.title))")
        for t in made { model.store.softDeleteNoUndo(t.id) }
        model.didMutate()
        model.isCaptureOpen = false
        await settle(300)
    }
}
#endif
