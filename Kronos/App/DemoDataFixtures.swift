// Kronos/App/DemoDataFixtures.swift
// A fictional store (Alex, Acme, Globex, Initech, Umbrella) that exercises every feature. It
// exists for the in-app UI test harness only, so it lives in the app target behind `!RELEASE`:
// a shipped app carries no sample data and offers no way to load any. (It used to sit in the core
// package, where the linker kept the public type, and its strings, in every build.)
//
// Everything created here goes through `TaskStoring`, never the model layer directly, so every
// write stays undo-correct exactly like a real user action would. `isMachineWrite` (no sounds) comes for free from `completeNoUndo`, the only
// call here that would otherwise post a completion sound; the rest of the load is one ordinary
// `groupedUndo` step so Cmd-Z removes the whole batch at once.

#if !RELEASE
import Foundation
import KronosCore

@MainActor
public enum DemoData {
    /// The label every row this file creates carries, so `remove(from:)` can find them again
    /// without guessing from titles or dates.
    public static let labelName = "demo"

    /// Populate `store` with 2 areas, 5 projects and ~30 tasks covering every feature. Safe to
    /// call twice: the second call is a no-op (detected via the `demo` label already existing
    /// with tagged tasks), so hitting the button twice never duplicates the sandbox.
    public static func load(into store: TaskStoring) {
        guard !alreadyLoaded(in: store) else { return }
        let today = Day.today()

        // `TaskStoring`'s protocol requirement has no default arguments (only the concrete
        // `TaskStore` does), so every call through the protocol type must state every
        // parameter; this wrapper keeps every call site below as short as `store.create` calls
        // read everywhere else.
        @discardableResult
        func make(title: String, notes: String = "", project: KProject? = nil,
                  priority: KPriority = .none, dueDay: Int? = nil) -> KTask {
            store.create(title: title, notes: notes, project: project,
                        status: .todo, priority: priority, dueDay: dueDay)
        }

        store.groupedUndo("Load demo data") {
            let demoLabel = store.label(named: labelName)

            // MARK: Areas + projects (2 areas, 5 projects, icon + colour each)
            let areaAlex = store.createArea(name: "Alex", colorHex: swatch("blue"), icon: "briefcase")
            let areaAcme = store.createArea(name: "Acme", colorHex: swatch("green"), icon: "building-2")

            let projWebsite  = store.createProject(name: "Website Relaunch", colorHex: swatch("blue"), icon: "globe", area: areaAlex)
            let projOnboard  = store.createProject(name: "Client Onboarding", colorHex: swatch("purple"), icon: "users", area: areaAlex)
            let projInvoices = store.createProject(name: "Invoices", colorHex: swatch("amber"), icon: "receipt", area: areaAcme)
            let projGlobex   = store.createProject(name: "Globex Campaign", colorHex: swatch("teal"), icon: "megaphone", area: areaAcme)
            let projPersonal = store.createProject(name: "Personal", colorHex: swatch("orange"), icon: "home", area: nil)

            @MainActor func tag(_ t: KTask) { store.addLabel(demoLabel, to: t.id) }

            // MARK: Priorities × efforts × deadlines (data-driven grid: 5 priorities × mixed effort/due)
            let grid: [(String, KPriority, KEffort, Int?, KProject?)] = [
                ("Pick the new logo direction",      .none,   .xs, nil,          projWebsite),
                ("Draft the homepage copy",           .low,    .s,  today + 5,    projWebsite),
                ("Review Umbrella Corp contract",     .medium, .m,  today,        projOnboard),
                ("Send Initech the proposal",         .high,   .l,  today - 2,    projOnboard),
                ("Fix the broken checkout link",      .urgent, .xs, today - 1,    projGlobex),
            ]
            for (title, priority, effort, due, project) in grid {
                let t = make(title: title, project: project, priority: priority, dueDay: due)
                store.setEffort(t.id, effort)
                tag(t)
            }

            // MARK: Deadlines: past / today / this week / none (beyond the grid above)
            let due = make(title: "Renew the domain", project: projWebsite, dueDay: today - 7)
            tag(due)
            let dueToday = make(title: "Call Acme about the invoice", project: projInvoices, dueDay: today)
            tag(dueToday)
            let dueWeek = make(title: "Prepare the Globex kickoff deck", project: projGlobex, dueDay: today + 4)
            tag(dueWeek)
            let noDue = make(title: "Sketch ideas for the newsletter", project: projWebsite)
            tag(noDue)

            // MARK: Subtasks, some done
            let checklist = make(title: "Ship the onboarding checklist", project: projOnboard)
            tag(checklist)
            store.addSubtask(checklist.id, title: "Send welcome email")
            if let s2 = store.addSubtask(checklist.id, title: "Create workspace") { store.toggleSubtask(s2.id) }
            store.addSubtask(checklist.id, title: "Schedule kickoff call")

            // MARK: Recurrence
            let weekly = make(title: "Weekly status update to Acme", project: projInvoices, dueDay: today + 1)
            store.setRecurrence(weekly.id, RecurrenceRule.weekly(every: 1, weekdays: [1], anchor: .fromDueDay).wireFormat)
            tag(weekly)

            // MARK: Waiting / someday
            let waiting = make(title: "Waiting on Initech's signed contract", project: projOnboard)
            store.setStatus(waiting.id, .waiting)
            tag(waiting)
            // No explicit someday setter (never a manual switch) — someday is reached by
            // giving a task a due day and then clearing it, exactly like clearing a deadline
            // in the inspector; that due-day CHANGE is what fires the store's automatic
            // status rule (a no-op write would not).
            let someday = make(title: "Maybe redesign the invoice template", project: projInvoices, dueDay: today)
            store.setDue(someday.id, day: nil)
            tag(someday)

            // MARK: Labels (beyond the demo tag itself)
            let urgentLabel = store.label(named: "follow-up")
            let followUp = make(title: "Follow up with Globex about assets", project: projGlobex)
            store.addLabel(urgentLabel, to: followUp.id)
            tag(followUp)

            // MARK: Notes, first move, depth, estimate, dread
            let rich = make(title: "Write the Q3 report", notes: "Pull numbers from last quarter first.", project: projInvoices)
            store.setFirstMove(rich.id, "Open the spreadsheet")
            store.setDepth(rich.id, .deep)
            store.setEstimate(rich.id, minutes: 90)
            store.setEffort(rich.id, .xl)
            tag(rich)

            let dreaded = make(title: "Call the accountant", project: projInvoices)
            store.setDread(dreaded.id, true)
            store.setFirstMove(dreaded.id, "Find their phone number")
            tag(dreaded)

            // MARK: Personal, no project
            let personal1 = make(title: "Book the dentist", project: projPersonal, priority: .low)
            tag(personal1)
            let personal2 = make(title: "Buy a birthday gift", project: projPersonal, dueDay: today + 2)
            tag(personal2)

            // MARK: Empty everything — nothing set beyond a title, so auto-triage has something
            // to fill (no priority, no due day, no project, no effort, no notes).
            let blank = make(title: "Look into the new invoicing tool")
            tag(blank)

            // MARK: Two near-duplicates, so neighbour triage has neighbours to compare.
            let dupA = make(title: "Email Alex about the contract renewal", project: projOnboard, priority: .medium)
            store.setEffort(dupA.id, .s)
            tag(dupA)
            let dupB = make(title: "Email Alex about contract renewal", project: projOnboard, priority: .medium)
            store.setEffort(dupB.id, .s)
            tag(dupB)

            // MARK: A few already-done tasks, to show completed state and history. Completed
            // through `completeNoUndo` on purpose: this is seed data appearing pre-finished,
            // not something the user just did, so no completion sound should fire and no
            // single undo step should let them un-complete a task they never completed.
            let done1 = make(title: "Set up the Globex workspace", project: projGlobex)
            store.completeNoUndo(done1.id)
            tag(done1)
            let done2 = make(title: "Send Umbrella the welcome pack", project: projOnboard)
            store.completeNoUndo(done2.id)
            tag(done2)

            // MARK: Padding out to ~30 total with plain, varied tasks across every project.
            let filler: [(String, KProject?, KPriority)] = [
                ("Update the pricing page",           projWebsite,  .low),
                ("Test the contact form",             projWebsite,  .none),
                ("Compress the hero images",          projWebsite,  .low),
                ("Prepare the Initech welcome deck",  projOnboard,  .medium),
                ("Chase the missing Acme invoice",    projInvoices, .high),
                ("Reconcile last month's expenses",   projInvoices, .medium),
                ("Draft the Globex ad copy",          projGlobex,   .medium),
                ("Pick stock photos for the campaign",projGlobex,   .none),
                ("Water the office plants",           projPersonal, .none),
            ]
            for (title, project, priority) in filler {
                tag(make(title: title, project: project, priority: priority))
            }
        }
    }

    /// Remove ONLY what `load(into:)` created: every task tagged `demo`, and any project whose
    /// EVERY live task was demo-tagged (archived rather than deleted — `TaskStoring` has no
    /// project delete, only archive). A pre-existing task, project or area the user already had
    /// is left untouched — the test proves this, including a real project the user separately
    /// named e.g. "Personal" that also holds a task of their own: that project keeps a non-demo
    /// task, so it never qualifies for archiving here. One grouped undo step, same as loading.
    ///
    /// The two demo areas (Alex, Acme) are deliberately left in place rather than force-emptied:
    /// `deleteArea` refuses a non-empty area, and archiving is not deleting, so removing them
    /// here would either throw silently or require deleting projects the store cannot delete.
    /// Two harmless empty-of-tasks areas are a smaller surprise than a silent no-op.
    public static func remove(from store: TaskStoring) {
        store.groupedUndo("Remove demo data") {
            let allLive = store.allTasks()
            let demoTasks = allLive.filter { ($0.labels ?? []).contains { $0.name == labelName } }
            let demoTaskIDs = Set(demoTasks.map(\.id))
            let touchedProjectIDs = Set(demoTasks.compactMap(\.projectID))

            for t in demoTasks { store.softDelete(t.id) }

            for project in store.allProjects(includeArchived: false) where touchedProjectIDs.contains(project.id) {
                let stillHasNonDemoTask = allLive.contains { $0.projectID == project.id && !demoTaskIDs.contains($0.id) }
                if !stillHasNonDemoTask { store.archiveProject(project.id) }
            }
        }
    }

    /// True once the demo label exists AND at least one live task still carries it — the guard
    /// `load(into:)` uses to stay idempotent on a second tap.
    /// Identity colours come from the design system's palette by name, so the fixture never
    /// carries a colour value of its own.
    private static func swatch(_ name: String) -> String {
        "#" + (KProjectPalette.swatches.first { $0.name == name }?.hex ?? KProjectPalette.swatches[0].hex)
    }

    private static func alreadyLoaded(in store: TaskStoring) -> Bool {
        store.allTasks().contains { task in (task.labels ?? []).contains { $0.name == labelName } }
    }
}
#endif
