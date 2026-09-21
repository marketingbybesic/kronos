// rev 4 — per-field filter negation.
//
// The contract: negation is PER FIELD and AND-combines with every other
// field, never "NOT (the whole filter)". A negated field with an empty
// constraint is inert, so ticking "not" before choosing a value does not
// make the user's list vanish. Old blobs decode as "nothing negated".

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct FilterNegationTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    @Test func filterNegationExcludesMatchingTasks() throws {
        let store = try makeStore()
        let today = Day.today()
        let urgent = store.create(title: "Hitno", notes: "", project: nil,
                                  status: .todo, priority: .urgent, dueDay: nil)
        let low = store.create(title: "Može čekati", notes: "", project: nil,
                               status: .todo, priority: .low, dueDay: nil)
        let medium = store.create(title: "Srednje", notes: "", project: nil,
                                  status: .todo, priority: .medium, dueDay: nil)

        var filter = KFilter()
        filter.priorities = [KPriority.urgent.rawValue]
        #expect(filter.matches(urgent, today: today))
        #expect(!filter.matches(low, today: today))

        filter.setNegated(.priorities, true)
        #expect(filter.isNegated(.priorities))
        // "is none of" — the constrained value is now the one excluded.
        #expect(!filter.matches(urgent, today: today))
        #expect(filter.matches(low, today: today))
        #expect(filter.matches(medium, today: today))

        // Multi-value negation means "none of these", not "not all of these".
        filter.priorities = [KPriority.urgent.rawValue, KPriority.low.rawValue]
        #expect(!filter.matches(urgent, today: today))
        #expect(!filter.matches(low, today: today))
        #expect(filter.matches(medium, today: today))

        filter.setNegated(.priorities, false)
        #expect(!filter.isNegated(.priorities))
        #expect(filter.matches(urgent, today: today))
    }

    @Test func negatedFieldAndCombinesWithEveryOtherField() throws {
        let store = try makeStore()
        let today = Day.today()
        let p = store.createProject(name: "Acme", colorHex: "#8224E3", icon: "circle", area: nil)

        let wanted = store.create(title: "Hitno izvan Acme", notes: "", project: nil,
                                  status: .todo, priority: .urgent, dueDay: nil)
        let wrongProject = store.create(title: "Hitno u Acme", notes: "", project: p,
                                        status: .todo, priority: .urgent, dueDay: nil)
        let wrongPriority = store.create(title: "Mlako izvan Acme", notes: "", project: nil,
                                         status: .todo, priority: .low, dueDay: nil)

        // "urgent AND NOT in Acme" — negation is per field, so the
        // positive priority constraint still applies normally.
        var filter = KFilter()
        filter.priorities = [KPriority.urgent.rawValue]
        filter.projectIDs = [p.id]
        filter.setNegated(.project, true)

        #expect(filter.matches(wanted, today: today))
        #expect(!filter.matches(wrongProject, today: today))
        #expect(!filter.matches(wrongPriority, today: today))
    }

    @Test func negatedFieldWithAnEmptyConstraintIsInert() throws {
        let store = try makeStore()
        let today = Day.today()
        let t = store.create(title: "Bilo što", notes: "", project: nil,
                             status: .todo, priority: .medium, dueDay: nil)

        // A user ticks "not" before choosing any value. Inverting "no
        // constraint" would mean "match nothing" and blank the whole list.
        var filter = KFilter()
        for field in KFilter.Field.allCases { filter.setNegated(field, true) }
        #expect(filter.matches(t, today: today))
        #expect(KFilter.empty.matches(t, today: today))
    }

    @Test func negationWorksOnEveryFieldKind() throws {
        let store = try makeStore()
        let today = Day.today()
        let area = store.createArea(name: "Klijenti", colorHex: "#8B8B93", icon: "person")
        let p = store.createProject(name: "Acme", colorHex: "#8224E3",
                                    icon: "circle", area: area)
        let label = store.label(named: "Žurno")

        let t = store.create(title: "Označeni zadatak", notes: "bilješke", project: p,
                             status: .todo, priority: .high, dueDay: today)
        store.addLabel(label, to: t.id)
        store.setDread(t.id, true)
        store.setEffort(t.id, .l)
        store.setDepth(t.id, .deep)
        store.addSubtask(t.id, title: "Korak")
        let task = try #require(store.task(t.id))

        // Each field, constrained to what this task IS, then negated: the
        // task must drop out every time. A field whose negation silently did
        // nothing would pass a positive-only test.
        var checks: [(KFilter.Field, KFilter)] = []
        func check(_ field: KFilter.Field, _ build: (inout KFilter) -> Void) {
            var f = KFilter(); build(&f); checks.append((field, f))
        }
        check(.statuses)    { $0.statuses = [KStatus.todo.rawValue] }
        check(.priorities)  { $0.priorities = [KPriority.high.rawValue] }
        check(.efforts)     { $0.efforts = [KEffort.l.rawValue] }
        check(.depths)      { $0.depths = [KDepth.deep.rawValue] }
        check(.project)     { $0.projectIDs = [p.id] }
        check(.area)        { $0.areaIDs = [area.id] }
        check(.labels)      { $0.labelIDs = [label.id] }
        check(.due)         { $0.due = .today }
        check(.dread)       { $0.dread = true }
        check(.hasNotes)    { $0.hasNotes = true }
        check(.hasSubtasks) { $0.hasSubtasks = true }
        check(.isSomeday)   { $0.isSomeday = false }
        check(.needsTriage) { $0.needsTriage = true }
        check(.text)        { $0.text = "označeni" }

        // Every filterable field is covered, so adding one without teaching
        // negation about it fails here rather than shipping half-negatable.
        #expect(checks.count == KFilter.Field.allCases.count)

        for (field, positive) in checks {
            #expect(positive.matches(task, today: today), "positive \(field) should match")
            var negated = positive
            negated.setNegated(field, true)
            #expect(!negated.matches(task, today: today), "negated \(field) should exclude")
        }
    }

    @Test func negatedFilterDecodesFromV1BlobAsNotNegated() throws {
        // A literal v1 blob: written before rev 4 existed, so it carries no
        // `negated` key at all. It must decode as "nothing negated", which is
        // exactly how it behaved when it was written — an old saved view must
        // not silently invert itself on upgrade.
        let v1 = """
        {"depths":[],"due":"today","labelIDs":[],"priorities":[4],\
        "projectIDs":[],"statuses":[0,1],"text":"račun","v":1}
        """
        let decoded = KFilter.decode(v1)
        #expect(decoded.negated.isEmpty)
        for field in KFilter.Field.allCases {
            #expect(!decoded.isNegated(field))
        }
        #expect(decoded.priorities == [KPriority.urgent.rawValue])
        #expect(decoded.statuses == [KStatus.todo.rawValue, KStatus.inProgress.rawValue])
        #expect(decoded.text == "račun")
        #expect(decoded.due == .today)

        // And it still behaves like a v1 filter, not an inverted one.
        let store = try makeStore()
        let today = Day.today()
        let hit = store.create(title: "Plati račun", notes: "", project: nil,
                               status: .todo, priority: .urgent, dueDay: today)
        #expect(decoded.matches(hit, today: today))
    }

    @Test func negationSurvivesAnEncodeDecodeRoundTrip() throws {
        var filter = KFilter()
        filter.statuses = [KStatus.todo.rawValue]
        filter.labelIDs = [UUID()]
        filter.setNegated(.labels, true)
        filter.setNegated(.statuses, true)

        let round = KFilter.decode(filter.encodedString)
        #expect(round == filter)
        #expect(round.isNegated(.labels))
        #expect(round.isNegated(.statuses))
        #expect(!round.isNegated(.priorities))

        // Encoding is stable regardless of the order the flags were set, so
        // G12's byte-identical export cannot be broken by a UI that toggles
        // them in a different sequence.
        var other = KFilter()
        other.statuses = filter.statuses
        other.labelIDs = filter.labelIDs
        other.setNegated(.statuses, true)
        other.setNegated(.labels, true)
        #expect(other.encodedString == filter.encodedString)

        // setNegated is idempotent: setting twice must not duplicate.
        other.setNegated(.labels, true)
        #expect(other.negated.count == 2)
        #expect(other.encodedString == filter.encodedString)
    }

    @Test func savedViewRoundTripsANegatedFilterThroughTheStore() throws {
        let store = try makeStore()
        var filter = KFilter()
        filter.priorities = [KPriority.low.rawValue]
        filter.setNegated(.priorities, true)

        let view = store.createSavedView(name: "Sve osim niskog", filter: filter,
                                         sort: [], showDone: false)
        // The view persists the filter as JSON, so negation has to survive
        // that hop or the saved view quietly means the opposite.
        #expect(view.filter.isNegated(.priorities))
        #expect(view.filter.priorities == [KPriority.low.rawValue])

        let refetched = try #require(store.allSavedViews().first)
        #expect(refetched.filter.isNegated(.priorities))
    }
}
