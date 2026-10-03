import Testing
import Foundation
@testable import KronosCore

/// Text -> tasks for the surfaces without an entry field (Services, App Intents, MCP, Capture).
/// Expectations are written by hand from the grammar, not computed by the code under test.
struct EntryTextTests {
    typealias F = EntryFixture

    private func plan(_ s: String, pills: [EntryPill] = []) -> [EntryPlannedTask] {
        EntryText.plan(s, directory: F.directory, today: F.today, pills: pills, languages: F.languages)
    }

    // MARK: plan

    struct Row {
        var input: String
        var title: String
        var dest: String?
        var subtasks: [String] = []
        var label: String? = nil
        var priority: KPriority = .none
    }

    static let rows: [Row] = [
        Row(input: "Call Anna #hit list @deep work !!", title: "Call Anna", dest: "Hit list", label: "deep work", priority: .medium),
        Row(input: "#Hit list call mom", title: "call mom", dest: "Hit list"),
        Row(input: "Plan trip #work > book flight > book hotel", title: "Plan trip", dest: "Work", subtasks: ["book flight", "book hotel"]),
        Row(input: "Plain sentence", title: "Plain sentence", dest: nil),
        Row(input: "  Pad it  ", title: "Pad it", dest: nil),
        Row(input: "#home paint the door", title: "paint the door", dest: "Home"),
    ]

    @Test func singleLineTable() {
        for row in Self.rows {
            let plans = plan(row.input)
            #expect(plans.count == 1, "\(row.input)")
            guard let p = plans.first else { continue }
            #expect(p.title == row.title, "\(row.input)")
            #expect(p.resolved.destination?.name == row.dest, "\(row.input)")
            #expect(p.subtasks == row.subtasks, "\(row.input)")
            #expect(p.resolved.labelName == row.label, "\(row.input)")
            #expect(p.resolved.priority == row.priority, "\(row.input)")
        }
    }

    @Test func linesBecomeTasksAndIndentBecomesSubtasks() {
        let plans = plan("Buy milk #hit list\nWrite report\n    outline\n    draft")
        #expect(plans.map(\.title) == ["Buy milk", "Write report"])
        #expect(plans[0].resolved.destination?.name == "Hit list")
        #expect(plans[1].subtasks == ["outline", "draft"])
    }

    @Test func linesWithNoTitleLeftAreSkipped() {
        #expect(plan("#hit list").isEmpty)
        #expect(plan("   \n\n").isEmpty)
        #expect(plan("#hit list\nReal task").map(\.title) == ["Real task"])
    }

    @Test func pillsAreDefaultsAndATypedTokenWins() {
        let hit = EntryDestination(kind: .project, name: "Hit list", id: F.hitList.id)
        let a = plan("Call mom", pills: [.destination(hit), .priority(.high)])
        #expect(a.first?.resolved.destination?.name == "Hit list")
        #expect(a.first?.resolved.priority == .high)
        let b = plan("Call mom #work", pills: [.destination(hit)])
        #expect(b.first?.resolved.destination?.name == "Work")
        #expect(b.first?.resolved.destination?.kind == .project)
    }

    // MARK: destination(named:)

    @Test func plainNameMatchTable() {
        let rows: [(String, EntryDestination.Kind?, String?)] = [
            ("Hit list", .project, "Hit list"),
            ("hit", .project, "Hit list"),            // prefix, directory order: Hit list before Hit parade
            ("HIT LIST", .project, "Hit list"),
            ("Home", .area, "Home"),                  // exact area beats the prefix project "Home renovation"
            ("home reno", .project, "Home renovation"),
            ("dakovo", .project, "Đakovo"),
            ("acme-skola", .project, "Acme škola"),
            ("Work", .project, "Work"),               // exact tier tie: project before area
            ("nonexistent", nil, nil),
            ("", nil, nil),
            ("   ", nil, nil),
        ]
        for (name, kind, expected) in rows {
            let d = EntryText.destination(named: name, directory: F.directory)
            #expect(d?.name == expected, "\(name)")
            #expect(d?.kind == kind, "\(name)")
        }
        #expect(EntryText.destination(named: "Hit list", directory: F.directory)?.id == F.hitList.id)
    }

    // MARK: intents

    @Test func intentPillsTable() {
        let d = F.directory
        #expect(EntryText.intentPills(projectName: nil, priorityRaw: 0, dueDay: nil, directory: d) == [])
        #expect(EntryText.intentPills(projectName: "nope", priorityRaw: 0, dueDay: nil, directory: d) == [])
        #expect(EntryText.intentPills(projectName: nil, priorityRaw: 99, dueDay: nil, directory: d) == [])
        let all = EntryText.intentPills(projectName: "hit list", priorityRaw: 3, dueDay: 20005, directory: d)
        #expect(all == [.destination(EntryDestination(kind: .project, name: "Hit list", id: F.hitList.id)),
                        .priority(.high), .due(20005)])
    }

    @Test func intentPlansHonourProjectNameAndKeepTokensOnlyText() {
        let d = F.directory
        let a = EntryText.intentPlans(text: "Call mom", projectName: "Hit list", priorityRaw: 0, dueDay: nil,
                                      directory: d, today: F.today)
        #expect(a.first?.resolved.destination?.name == "Hit list")
        // A token in the text beats the parameter.
        let b = EntryText.intentPlans(text: "Call mom #work", projectName: "Hit list", priorityRaw: 0, dueDay: nil,
                                      directory: d, today: F.today)
        #expect(b.first?.resolved.destination?.name == "Work")
        // Nothing but a token: the text itself is the title, the parameter's project still applies.
        let c = EntryText.intentPlans(text: "#home", projectName: "Hit list", priorityRaw: 0, dueDay: nil,
                                      directory: d, today: F.today)
        #expect(c.map(\.title) == ["#home"])
        #expect(c.first?.resolved.destination?.name == "Hit list")
        #expect(EntryText.intentPlans(text: "  ", projectName: "Hit list", priorityRaw: 0, dueDay: nil,
                                      directory: d, today: F.today).isEmpty)
    }

    @MainActor
    @Test func intentCreationThroughTheStore() throws {
        let store = try TaskStore(inMemory: true)
        let hit = store.createProject(name: "Hit list", colorHex: "#445566", icon: nil, area: nil)
        let home = store.createArea(name: "Home", colorHex: "#112233", icon: "house")
        _ = store.label(named: "deep work")
        let plans = EntryText.intentPlans(text: "Plan trip #home @deep work !!! *m > book flight",
                                          projectName: "hit", priorityRaw: 0, dueDay: nil,
                                          directory: store.entryDirectory(), today: F.today)
        let made = store.createTasks(from: plans, undoName: "Add")
        #expect(made.count == 1)
        let t = try #require(store.allTasks().first)
        #expect(t.title == "Plan trip")
        // The #home area token beats the parameter's project.
        #expect(t.areaID == home.id)
        #expect(t.project == nil)
        #expect(t.priority == .high)
        #expect(t.effort == .m)
        #expect(t.labels?.map(\.name) == ["deep work"])
        #expect(t.orderedSubtasks.map(\.title) == ["book flight"])

        // Parameter only: the project is honoured.
        let plain = EntryText.intentPlans(text: "Call mom", projectName: "Hit", priorityRaw: 2, dueDay: F.today + 3,
                                          directory: store.entryDirectory(), today: F.today)
        let m2 = store.createTasks(from: plain, undoName: "Add")
        #expect(m2.first?.project?.id == hit.id)
        #expect(m2.first?.priority == .medium)
        #expect(m2.first?.dueDay == F.today + 3)
    }

    // MARK: Services

    @Test func servicesSplitTable() {
        let rows: [(String, String?, String?)] = [
            ("Call Anna #hit list", "Call Anna #hit list", ""),
            ("Title\nsecond line\n\n  third  ", "Title", "second line\nthird"),
            ("\n\n  First after blanks \nrest", "First after blanks", "rest"),
            ("only\r\nwindows", "only", "windows"),
            ("   \n  ", nil, nil),
            ("", nil, nil),
        ]
        for (input, line, notes) in rows {
            let got = EntryText.servicesSplit(input)
            #expect(got?.line == line, "\(input.debugDescription)")
            #expect(got?.notes == notes, "\(input.debugDescription)")
        }
    }

    // MARK: Capture pills

    @Test func captureProposalPills() {
        var p = ProposedTask(title: "Send offer", projectName: "Hit list", labelNames: ["finance", "deep work"],
                             priority: .high, effort: .m, dueDay: 20001, sourceLine: "x")
        #expect(EntryText.pills(for: p) == [
            .destination(EntryDestination(kind: .project, name: "Hit list")),
            .label("finance"), .label("deep work"), .priority(.high), .effort(.m), .due(20001),
        ])
        p = ProposedTask(title: "Plain", sourceLine: "Plain")
        #expect(EntryText.pills(for: p).isEmpty)
    }
}
