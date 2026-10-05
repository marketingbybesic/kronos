import Testing
import Foundation
@testable import KronosCore

/// A saved view made inside a project is a filter pinned to that project: nothing is stored beyond the
/// filter, the pin is read back off it, survives Clear all, and rides along with export and import.
@MainActor
@Suite("SavedViewScopeTests")
struct SavedViewScopeTests {

    private let projectA = UUID()
    private let projectB = UUID()
    private let today = 1000

    // MARK: pinned(to:)

    @Test("pinning replaces every project choice and the inversion, and keeps every other field")
    func pinnedReplacesProjectChoice() {
        var f = KFilter()
        f.projectIDs = [projectB, projectA]
        f.noProject = true
        f.setNegated(.project, true)
        f.priorities = [KPriority.high.rawValue]
        f.text = "invoice"

        let pinned = f.pinned(to: projectA)

        #expect(pinned.projectIDs == [projectA])
        #expect(pinned.noProject == false)
        #expect(pinned.isNegated(.project) == false)
        #expect(pinned.priorities == [KPriority.high.rawValue])
        #expect(pinned.text == "invoice")
    }

    @Test("pinnedProjectID answers only for exactly one project, plainly chosen")
    func pinnedProjectIDTable() {
        var none = KFilter(); none.priorities = [1]
        var two = KFilter(); two.projectIDs = [projectA, projectB]
        var withNone = KFilter(); withNone.projectIDs = [projectA]; withNone.noProject = true
        var inverted = KFilter(); inverted.projectIDs = [projectA]; inverted.setNegated(.project, true)
        var one = KFilter(); one.projectIDs = [projectA]

        #expect(KFilter.empty.pinnedProjectID == nil)
        #expect(none.pinnedProjectID == nil)
        #expect(two.pinnedProjectID == nil)
        #expect(withNone.pinnedProjectID == nil)
        #expect(inverted.pinnedProjectID == nil)
        #expect(one.pinnedProjectID == projectA)
        #expect(KFilter.empty.pinned(to: projectB).pinnedProjectID == projectB)
    }

    @Test("a view written before the pin existed (one project in the filter, no negation key) belongs to that project")
    func oldBlobDecodesToHome() {
        let json = "{\"projectIDs\":[\"\(projectA.uuidString)\"],\"v\":1}"
        let decoded = KFilter.decode(json)
        #expect(decoded.pinnedProjectID == projectA)
    }

    // MARK: KSavedView.homeProjectID + memberCount

    @Test("a stored view reports its home project from its filter; a global one reports none")
    func homeProjectOfStoredViews() throws {
        let store = try TaskStore(inMemory: true)
        let project = store.createProject(name: "Home")
        let inProject = store.createSavedView(name: "In project", filter: KFilter().pinned(to: project.id), sort: [], showDone: false)
        let global = store.createSavedView(name: "Global", filter: KFilter(), sort: [], showDone: false)
        var two = KFilter(); two.projectIDs = [project.id, UUID()]
        let several = store.createSavedView(name: "Several", filter: two, sort: [], showDone: false)

        #expect(inProject.homeProjectID == project.id)
        #expect(global.homeProjectID == nil)
        #expect(several.homeProjectID == nil)
    }

    @Test("the number beside a view counts its open tasks of that project and nothing else")
    func memberCountTable() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createProject(name: "P")
        let q = store.createProject(name: "Q")
        let open1 = store.create(title: "open 1", notes: "", project: p, status: .todo, priority: .none, dueDay: nil)
        _ = store.create(title: "waiting", notes: "", project: p, status: .waiting, priority: .none, dueDay: nil)
        let done = store.create(title: "done", notes: "", project: p, status: .todo, priority: .none, dueDay: nil)
        store.update(done.id) { $0.status = .done }
        _ = store.create(title: "other project", notes: "", project: q, status: .todo, priority: .none, dueDay: nil)
        let gone = store.create(title: "deleted", notes: "", project: p, status: .todo, priority: .none, dueDay: nil)
        store.softDelete(gone.id)
        store.setPriority(open1.id, .high)

        let all = store.allTasks()
        let plain = store.createSavedView(name: "All of P", filter: KFilter().pinned(to: p.id), sort: [], showDone: false)
        var urgentOnly = KFilter().pinned(to: p.id)
        urgentOnly.priorities = [KPriority.high.rawValue]
        let narrowed = store.createSavedView(name: "High of P", filter: urgentOnly, sort: [], showDone: false)

        #expect(plain.memberCount(in: all, today: today) == 2)
        #expect(narrowed.memberCount(in: all, today: today) == 1)
    }

    // MARK: Clear all

    @Test("Clear all drops every sort and filter but the pin, and keeps Show completed")
    func clearedKeepingPin() {
        var f = KFilter().pinned(to: projectA)
        f.priorities = [KPriority.low.rawValue]
        f.text = "x"
        let opts = ViewOptions(sort: [.desc(.priority)], filter: f, showCompleted: true)

        let expected = ViewOptions(sort: KSortDescriptor.default, filter: KFilter().pinned(to: projectA), showCompleted: true)
        #expect(opts.cleared(keepingPin: projectA) == expected)
        // No pin: exactly the old Clear all.
        #expect(opts.cleared(keepingPin: nil) == opts.cleared())
        #expect(opts.cleared(keepingPin: nil).filter == .empty)
    }

    @Test("Clear all is offered only for something beyond the pin; a lost pin counts as something to restore")
    func hasRulesToClearKeepingPin() {
        let pinnedOnly = ViewOptions(sort: KSortDescriptor.default, filter: KFilter().pinned(to: projectA), showCompleted: false)
        #expect(pinnedOnly.hasRulesToClear(keepingPin: projectA) == false)

        var withText = pinnedOnly; withText.filter.text = "x"
        #expect(withText.hasRulesToClear(keepingPin: projectA))

        var sorted = pinnedOnly; sorted.sort = [.asc(.title)]
        #expect(sorted.hasRulesToClear(keepingPin: projectA))

        let lost = ViewOptions.default
        #expect(lost.hasRulesToClear(keepingPin: projectA))
        #expect(lost.hasRulesToClear(keepingPin: nil) == false)

        // Without a pin any filter at all counts as something to clear.
        var f = KFilter(); f.priorities = [1]
        #expect(ViewOptions(filter: f).hasRulesToClear(keepingPin: nil))
    }

    // MARK: Export and import

    @Test("a pinned view survives export, wipe and import with the same filter and the same home project")
    func exportImportRoundTrip() throws {
        let store = try TaskStore(inMemory: true)
        let project = store.createProject(name: "Round trip")
        var filter = KFilter().pinned(to: project.id)
        filter.priorities = [KPriority.high.rawValue]
        _ = store.createSavedView(name: "Pinned", filter: filter, sort: [.desc(.priority)], showDone: true)

        let envelope = JSONExporter(store: store).makeEnvelope()
        let exported = try #require(envelope.savedViews.first)
        #expect(exported.filter.encodedString == filter.encodedString)

        let store2 = try TaskStore(inMemory: true)
        _ = KronosImporter(store: store2).importEnvelope(envelope, mode: .replace)
        let imported = try #require(store2.allSavedViews().first)
        #expect(imported.filter == filter)
        #expect(imported.homeProjectID == project.id)
        #expect(JSONExporter(store: store2).makeEnvelope().savedViews.first?.filter.encodedString == filter.encodedString)
    }
}
