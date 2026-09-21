// Kronos/Triage/TriageFieldMenus.swift. Split out of TriageFlowView.swift to keep that file
// under the 500-line lint gate. The four per-field value controls a triage card shows, plus
// the preview/formatting helpers only they use.
import SwiftUI
import KronosCore

extension TriageFlowView {

    // MARK: Field menus — each shows the live value; the suggestion is already applied to it
    // via `previewValue`, so the row shown IS the accepted value on Return.

    func priorityMenu(for task: KTask) -> some View {
        KAttributeMenu(options: KPriority.allCases, selected: previewPriority(for: task),
                       title: { $0.localizedName }, level: { $0.rawValue }, steps: 4, kind: .priority) { picked in
            lockedFields.insert(.priority)
            model.store.setPriority(task.id, picked)
            model.didMutate()
        }
    }

    func effortMenu(for task: KTask) -> some View {
        KAttributeMenu(options: KEffort.allCases, selected: previewEffort(for: task),
                       title: { $0.localizedName }, level: { $0.rawValue }, steps: 5, kind: .effort) { picked in
            lockedFields.insert(.effort)
            model.store.setEffort(task.id, picked)
            model.didMutate()
        }
    }

    /// The menu picker, or — while `isEditingDate` (opened by the D key or the "Upiši datum"
    /// item below) — a text field that accepts whatever quick add accepts ("sutra", "25.9.",
    /// "25.9.2026.", "2026-12-01"). G5: "deadline mora imat opciju da upisem datum isto".
    func deadlineRow(for task: KTask) -> some View {
        Group {
            if isEditingDate {
                KTextField(String(localized: "triage.flow.date.placeholder"), text: $dateText)
                    .focused($isDateFieldFocused)
                    .onSubmit { commitTypedDate(for: task) }
                    .uiTestAnchor("triage.card.date")
            } else {
                deadlineMenu(for: task)
            }
        }
    }

    func deadlineMenu(for task: KTask) -> some View {
        let today = Day.today(calendar: KronosLocale.calendar)
        let day = previewDueDay(for: task)
        return KMenuButton(text: deadlineText(day: day, today: today)) {
            Button(String(localized: "deadline.quick.today")) { setDeadline(.today) }
            Button(String(localized: "deadline.quick.tomorrow")) { setDeadline(.tomorrow) }
            Button(String(localized: "deadline.quick.nextweek")) { setDeadline(.thisWeek) }
            Button(String(localized: "deadline.quick.none")) { setDeadline(.none) }
            Button(String(localized: "triage.flow.date.typeit")) { openDateField() }
        }
    }

    func openDateField() {
        dateText = ""
        isEditingDate = true
        DispatchQueue.main.async { isDateFieldFocused = true }
    }

    /// Reuses the SAME grammar quick add's title field uses: reuse Core
    /// QuickAddParser.parseDayMonth / Day.parseISO, do not write a second date parser.
    /// `parseDayMonth` itself is package-internal (not `public`), so the only reachable seam
    /// from this app target is `QuickAddParser.parse`'s public entry point, which tries
    /// `Day.parseISO` then `parseDayMonth` internally on a bare date token — passing the typed
    /// text through it with no projects gives exactly the same date resolution quick add uses,
    /// with zero project/label/priority side effects since none of those tokens are present.
    func commitTypedDate(for task: KTask) {
        let trimmed = dateText.trimmingCharacters(in: .whitespaces)
        defer { isEditingDate = false }
        guard !trimmed.isEmpty else { return }
        let today = Day.today(calendar: KronosLocale.calendar)
        let parsed = QuickAddParser().parse(trimmed, projects: [], today: today)
        guard let day = parsed.dueDay else { return }   // unparsable text: silently keep the old value, no error UI for a triage card
        lockedFields.insert(.due)
        model.store.setDue(task.id, day: day)
        model.didMutate()
    }

    func projectMenu(for task: KTask) -> some View {
        let projects = model.store.allProjects()
        return KMenuButton(text: task.project?.name ?? String(localized: "triage.flow.noproject")) {
            Button(String(localized: "triage.flow.noproject")) {
                lockedFields.insert(.project)
                model.store.move(task.id, toProject: nil)
                model.didMutate()
            }
            ForEach(projects) { project in
                Button(project.name) {
                    lockedFields.insert(.project)
                    model.store.move(task.id, toProject: project)
                    model.didMutate()
                }
            }
        }
    }

    // MARK: Preview values — the suggestion overlays the task's own value ONLY where the
    // task's own field is still empty, so a field already set by hand (or quick-add) is
    // shown and edited as-is, never silently swapped for the model's guess.

    func previewPriority(for task: KTask) -> KPriority {
        guard task.priority == .none, let p = suggestion.flatMap({ KPriority(rawValue: $0.priority) }) else { return task.priority }
        return p
    }
    func previewEffort(for task: KTask) -> KEffort {
        guard task.effort == .none, let e = suggestion?.effort else { return task.effort }
        return e
    }
    func previewDueDay(for task: KTask) -> Int? {
        guard task.dueDay == nil, let due = suggestion?.due, let day = Day.parseISO(due) else { return task.dueDay }
        return day
    }

    /// Same shape as `QuickAddPanelView.relativeDay` (that file's own private helper): each
    /// caller formats its own day, always with `KronosLocale.current`/`.calendar`, never
    /// `Locale.current`.
    func deadlineText(day: Int?, today: Int) -> String {
        guard let day else { return String(localized: "deadline.quick.none") }
        let calendar = KronosLocale.calendar
        let date = Day.date(day, calendar: calendar)
        if day == today { return String(localized: "deadline.quick.today") }
        if day == today + 1 { return String(localized: "deadline.quick.tomorrow") }
        if day > today, day - today < 7 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = KronosLocale.current
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = KronosLocale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}

extension KPriority {
    var localizedName: String {
        switch self {
        case .none: String(localized: "priority.none")
        case .low: String(localized: "priority.low")
        case .medium: String(localized: "priority.medium")
        case .high: String(localized: "priority.high")
        case .urgent: String(localized: "priority.urgent")
        }
    }
}
extension KEffort {
    var localizedName: String {
        switch self {
        case .none: String(localized: "effort.none")
        case .xs: String(localized: "effort.xs")
        case .s: String(localized: "effort.s")
        case .m: String(localized: "effort.m")
        case .l: String(localized: "effort.l")
        case .xl: String(localized: "effort.xl")
        }
    }
}

/// Same shape as Kronos/Palette/CommandPaletteView.swift's private `KeyCatcher` (file-private
/// there, so a same-shape copy here rather than reaching into another leaf's OWNS), plus a
/// window-identity guard that one does not need: this monitor fires for every keyDown in the
/// app, and triage shares its NSWindow with every other AppShellView overlay (Palette/
/// TimeBlocks/Impuls/Capture/Keymap all live in the same ZStack, and AppShellView's own
/// `.onExitCommand` cascade checking the palette before triage proves they can stack) —
/// `view.window` read live off the NSView, checked against `event.window` and `isKeyWindow`,
/// is what actually scopes this to triage's own window; relying on AppKit's undocumented
/// monitor call order instead would be a coin flip. `internal`, not `private`, so
/// TriageFlowView.swift (same target) can use it — see that file's own note on this pattern.
struct TriageKeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        DispatchQueue.main.async { [weak view] in
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Wrong window, or the window isn't key (e.g. Settings opened over it): never
                // touch the event, so whatever DOES own it still gets it.
                guard let cardWindow = view?.window, event.window === cardWindow, cardWindow.isKeyWindow else {
                    return event
                }
                return onKey(event) ? nil : event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
