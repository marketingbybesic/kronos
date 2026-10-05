// Live steps for the inspector's two popovers: Repeat and Deadline.
//  A. Both popovers are opened from the real inspector (click the Repeat row, click the Deadline
//     control) and their own anchors are measured: the Repeat content sits at least 12 pt inside
//     its popover on every side; the Deadline calendar spans the popover's full width.
//  B. The shipped popover views are rendered offscreen at text size M and L: nothing of the Repeat
//     picker is wider than its inset box, and no accent-coloured focus ring is drawn around the
//     calendar.
// Run alone with `--only group:I-INSPECT`. `--break` demands impossible insets and must fail.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    private static var iiBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    static func iInspectSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await iiOpenPopovers($0) }
        await runStep(model, scope: .all) { await iiRenderShipped($0) }
        await runStep(model, scope: .all) { _ in iiMonthTable() }
    }

    // MARK: C. Month arithmetic against a hand-written table

    private static func iiMonthTable() {
        func make(firstWeekday: Int) -> Calendar {
            var c = Calendar(identifier: .gregorian)
            c.locale = Locale(identifier: "en_US")
            c.firstWeekday = firstWeekday
            return c
        }
        func date(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date {
            c.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date.distantPast
        }
        func describe(_ days: [Date], _ c: Calendar) -> String {
            guard let f = days.first, let l = days.last else { return "empty" }
            func p(_ d: Date) -> String { "\(c.component(.month, from: d))/\(c.component(.day, from: d))" }
            return "\(days.count):\(p(f))-\(p(l))"
        }
        let mon = make(firstWeekday: 2), sun = make(firstWeekday: 1)
        // Oct 1 2026 is a Thursday. Mon-first: 3 leading days (Sep 28), 31 days, 35 cells to Nov 1.
        // Sun-first: 4 leading (Sep 27), 35 cells to Oct 31. Feb 2027 starts on a Monday and has 28 days.
        let wantOct = iiBreak ? "42:9/28-11/8" : "35:9/28-11/1"
        let gotOct = describe(DeadlineMonth.days(of: date(2026, 10, 15, mon), calendar: mon), mon)
        let gotOctSun = describe(DeadlineMonth.days(of: date(2026, 10, 15, sun), calendar: sun), sun)
        let gotFeb = describe(DeadlineMonth.days(of: date(2027, 2, 9, mon), calendar: mon), mon)
        let headers = DeadlineMonth.weekdayHeaders(calendar: mon)
        record("deadline calendar month grid matches a hand-written table (Mon-first, Sun-first, 28-day month, headers)",
               gotOct == wantOct && gotOctSun == "35:9/27-10/31" && gotFeb == "28:2/1-2/28"
                   && headers == ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"],
               "oct=\(gotOct) octSun=\(gotOctSun) feb=\(gotFeb) headers=\(headers)")
    }

    // MARK: A. Real popovers

    private static func iiOpenPopovers(_ model: AppModel) async {
        let store = model.store
        let detailsKey = "kronos.inspector.detailsOpen"
        let wasOpen = UserDefaults.standard.bool(forKey: detailsKey)
        UserDefaults.standard.set(true, forKey: detailsKey)
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)

        let task = store.create(title: "iinspect.popovers", notes: "", project: nil, status: .todo, priority: .none,
                                dueDay: Day.today() + 2)
        store.setRecurrence(task.id, RecurrenceRule.weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay).wireFormat)
        model.didMutate()
        await settle(500)
        model.selectedTaskID = task.id
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["inspector.due"] != nil && UITestAnchors.frames["inspector.recurrence"] != nil }
        await settle(300)
        defer {
            UserDefaults.standard.set(wasOpen, forKey: detailsKey)
            store.softDelete(task.id)
            model.didMutate()
        }

        // Repeat popover.
        // The row sits at the bottom of the open Details list, on the window's edge: scroll the inspector
        // to its end so the click lands on the row, not on the backdrop behind it.
        iiScroll(window.contentView, toEnd: true)
        await settle(400)
        let rowThere = UITestAnchors.frames["inspector.recurrence"] != nil
        _ = await click("inspector.recurrence", xFraction: 0.6)
        let repeatOpen = await waitUntil(timeout: 3) { UITestAnchors.frames["recurrence.popover.root"] != nil }
        await settle(300)
        let root = UITestAnchors.frames["recurrence.popover.root"] ?? .zero
        let content = UITestAnchors.frames["recurrence.popover.content"] ?? .zero
        let wantInset: CGFloat = iiBreak ? 60 : 12
        let insets = [content.minX - root.minX, content.minY - root.minY, root.maxX - content.maxX, root.maxY - content.maxY]
        // The anchor measures the frame the picker was OFFERED; what it asks for must fit inside it too,
        // or it overflows the padding (the segmented anchor control did: 274 pt asked, 256 offered).
        let ideal = NSHostingView(rootView: InspectorRecurrenceEditor(
            rule: .weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay), locale: KronosLocale.languageCode) { _ in }).fittingSize.width
        record("repeat popover opens from the Repeat row and its content sits >= \(Int(wantInset)) pt inside the popover on every side",
               rowThere && repeatOpen && root.width > 100 && insets.allSatisfy { $0 >= wantInset } && ideal <= root.width - 2 * wantInset,
               "row=\(rowThere) open=\(repeatOpen) root=\(root) content=\(content) insets=\(insets) idealW=\(ideal)")
        key("\u{1b}", keyCode: 53)
        await waitUntil(timeout: 2) { UITestAnchors.frames["recurrence.popover.root"] == nil }
        await settle(300)

        // Deadline popover.
        iiScroll(window.contentView, toEnd: false)
        await settle(400)
        _ = await click("inspector.due", xFraction: 0.3)
        let dueOpen = await waitUntil(timeout: 3) { UITestAnchors.frames["deadline.popover.calendar"] != nil }
        await settle(500)
        let dRoot = UITestAnchors.frames["deadline.popover.root"] ?? .zero
        let cal = UITestAnchors.frames["deadline.popover.calendar"] ?? .zero
        let header = UITestAnchors.frames["deadline.popover.header"] ?? .zero
        let leftGap = cal.minX - dRoot.minX, rightGap = dRoot.maxX - cal.maxX
        // Break mode demands a 20 pt margin the calendar must not have.
        let edgeToEdge = iiBreak ? (leftGap >= 20 && rightGap >= 20) : (abs(leftGap) <= 1 && abs(rightGap) <= 1)
        record("deadline popover opens from the Deadline control and its calendar spans the popover edge to edge",
               dueOpen && dRoot.width > 150 && edgeToEdge,
               "open=\(dueOpen) root=\(dRoot) cal=\(cal) gaps=\(leftGap),\(rightGap)")
        // The day cells themselves fill the width: leftmost cell left edge and rightmost right edge sit
        // within 24 pt of the popover edges (12 pt inset + the cell's own centring in its column).
        let cells = UITestAnchors.frames.filter { $0.key.hasPrefix("deadline.popover.day.") || $0.key.hasPrefix("deadline.popover.outside.") }.map(\.value)
        let cellSpan = (cells.map(\.maxX).max() ?? 0) - (cells.map(\.minX).min() ?? 0)
        let dueCell = UITestAnchors.frames["deadline.popover.day.\(Day.today() + 2)"] != nil
            || UITestAnchors.frames["deadline.popover.outside.\(Day.today() + 2)"] != nil
        record("deadline popover day cells run across the popover width and the due day is drawn",
               cells.count >= 28 && dueCell && cellSpan >= dRoot.width - (iiBreak ? 4 : 40),
               "cells=\(cells.count) span=\(cellSpan) root=\(dRoot.width) dueCell=\(dueCell)")
        record("deadline popover header spans the popover and the popover is at most 420 pt tall",
               abs(header.width - dRoot.width) <= 1 && dRoot.height > 0 && dRoot.height <= 420,
               "header=\(header) rootH=\(dRoot.height)")
        key("\u{1b}", keyCode: 53)
        await waitUntil(timeout: 2) { UITestAnchors.frames["deadline.popover.root"] == nil }
        await settle(300)
    }


    private static func iiScroll(_ view: NSView?, toEnd: Bool) {
        guard let view else { return }
        if let scroll = view as? NSScrollView, let doc = scroll.documentView {
            let clip = scroll.contentView
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: (doc.isFlipped == toEnd) ? maxY : 0))
            scroll.reflectScrolledClipView(clip)
        }
        for sub in view.subviews { iiScroll(sub, toEnd: toEnd) }
    }

    // MARK: B. Shipped views rendered at text size M and L

    private static func iiRenderShipped(_ model: AppModel) async {
        let store = model.store
        let task = store.create(title: "iinspect.render", notes: "", project: nil, status: .todo, priority: .none,
                                dueDay: Day.today() + 3)
        model.didMutate()
        defer { DSScale.apply(density: "regular", textSize: "M"); store.softDelete(task.id); model.didMutate() }

        let dir = ProcessInfo.processInfo.environment["KRONOS_SHOT_DIR"]
        for (size, factor) in [("M", 1.0), ("L", 1.1)] as [(String, Double)] {
            DSScale.apply(density: "regular", textSize: size)
            _ = factor
            let repeatView = InspectorRecurrencePopover(rule: .weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay),
                                                        locale: KronosLocale.languageCode) { _ in }
            let r = await iiRender(AnyView(repeatView), name: "iinspect-repeat-\(size)", dir: dir)
            let editorWidth = NSHostingView(rootView: InspectorRecurrenceEditor(
                rule: .weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay), locale: KronosLocale.languageCode) { _ in })
                .fittingSize.width
            let boxWidth = InspectorRecurrencePopover.width - 2 * InspectorRecurrencePopover.inset
            record("repeat popover at text size \(size): whole picker fits its inset box, drawn, no red",
                   editorWidth <= boxWidth + 0.5 && r.lit > 200 && r.red == 0,
                   "editorW=\(editorWidth) boxW=\(boxWidth) lit=\(r.lit) red=\(r.red) png=\(r.path)")

            let deadlineView = InspectorDeadlinePopover(model: model, task: task)
            let d = await iiRender(AnyView(deadlineView), name: "iinspect-deadline-\(size)", dir: dir)
            record("deadline popover at text size \(size): drawn, no accent-coloured ring, no red",
                   d.lit > 500 && d.accentRing == 0 && d.red == 0,
                   "lit=\(d.lit) accentRing=\(d.accentRing) red=\(d.red) size=\(d.width)x\(d.height) png=\(d.path)")
        }
    }

    private struct IIRender { var lit = 0, red = 0, accentRing = 0, width = 0, height = 0, path = "-" }

    private static func iiRender(_ view: AnyView, name: String, dir: String?) async -> IIRender {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).fixedSize())
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.backgroundColor = .black
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        await settle(500)
        host.layoutSubtreeIfNeeded()
        var out = IIRender()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return out }
        host.cacheDisplay(in: host.bounds, to: rep)
        out.width = rep.pixelsWide; out.height = rep.pixelsHigh
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let p = rgb(x, y)
                if max(p.0, p.1, p.2) > 0.1 { out.lit += 1 }
                if p.0 - max(p.1, p.2) > 0.08 { out.red += 1 }
            }
        }
        // A focus ring is a 2-3 px line of the accent colour hugging the calendar: purple = blue high,
        // red mid, green low. Count such pixels on the four outer rows/columns of the inner area
        // (below the header hairline), where the old ring ran; the selected-day disc is far inside.
        let bandTop = h / 3
        for y in bandTop..<h {
            for x in [0, 1, 2, 3, w - 4, w - 3, w - 2, w - 1] where x >= 0 && x < w {
                let p = rgb(x, y)
                if p.2 > 0.85 && p.0 > 0.55 && p.1 < 0.65 { out.accentRing += 1 }
            }
        }
        if let dir, FileManager.default.fileExists(atPath: dir), let png = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            if (try? png.write(to: url)) != nil { out.path = url.path }
        }
        win.contentView = nil
        return out
    }
}
#endif
