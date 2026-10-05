import Testing
import Foundation
@testable import KronosCore

/// w22e: task templates. JSON file round trip, quick add `/name rest` parsing, create-from-template.
@MainActor
struct TemplateTests {

    private let weekly = TaskTemplate(name: "Weekly review", title: "Weekly review",
                                      subtasks: ["Inbox zero", "Plan next week"],
                                      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    private let invoice = TaskTemplate(name: "Račun", title: "Izdati račun")
    private let call = TaskTemplate(name: "call", title: "Call")

    // MARK: file round trip

    @Test func fileRoundTripKeepsEveryField() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-tpl-\(UUID().uuidString)/templates.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pid = UUID()
        let t = TaskTemplate(name: "Šator", title: "Čišćenje šatora", notes: "đ ž", subtasks: ["a", "b"],
                             projectID: pid, projectName: "Đakovo", priorityRaw: KPriority.high.rawValue,
                             effortRaw: KEffort.l.rawValue, estimateMinutes: 45,
                             createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try TemplateFile.write([t, weekly], to: url)
        let back = try TemplateFile.read(from: url)
        #expect(back.count == 2)
        #expect(back.first { $0.id == t.id } == t)
    }

    @Test func missingFileIsEmptyAndCorruptFileThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-tpl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("templates.json")
        #expect(try TemplateFile.read(from: url).isEmpty)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try TemplateFile.read(from: url) }
    }

    @Test func tolerantDecodeOfSparseTemplate() throws {
        let json = #"{"version":1,"templates":[{"title":"Only a title"}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-tpl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let t = try #require(try TemplateFile.read(from: url).first)
        #expect(t.name == "Only a title" && t.subtasks.isEmpty && t.priorityRaw == 0)
    }

    @Test func envelopeTemplatesAreOptionalBothWays() throws {
        let store = try TaskStore(inMemory: true)
        var env = JSONExporter(store: store).makeEnvelope(now: Date(timeIntervalSince1970: 0))
        #expect(env.templates == nil)
        env.templates = [weekly]
        let data = try KronosExportCodec.makeEncoder().encode(env)
        let back = try KronosExportCodec.makeDecoder().decode(KronosExportEnvelope.self, from: data)
        #expect(back.templates == [weekly])
        // and the importer ignores the key without failing
        _ = try KronosImporter(store: try TaskStore(inMemory: true)).importData(data, mode: .replace)
        let plain = try KronosExportCodec.makeEncoder().encode(JSONExporter(store: store).makeEnvelope())
        #expect(!String(decoding: plain, as: UTF8.self).contains("templates"))
    }

    // MARK: quick add parse

    @Test func slashDetection() {
        #expect(TemplateQuery.isTemplateInput("/weekly"))
        #expect(TemplateQuery.isTemplateInput("  /weekly"))
        #expect(!TemplateQuery.isTemplateInput("weekly /x"))
        #expect(!TemplateQuery.isTemplateInput(""))
    }

    @Test func suggestionsPrefixThenContains() {
        let all = [weekly, invoice, call]
        #expect(TemplateQuery.suggestions(for: "/", in: all).count == 3)
        #expect(TemplateQuery.suggestions(for: "/wee", in: all) == [weekly])
        #expect(TemplateQuery.suggestions(for: "/rac", in: all) == [invoice], "accent folded")
        #expect(TemplateQuery.suggestions(for: "/review", in: all) == [weekly], "contains fallback")
        #expect(TemplateQuery.suggestions(for: "/zzz", in: all).isEmpty)
        #expect(TemplateQuery.suggestions(for: "plain", in: all).isEmpty)
    }

    @Test func resolveLongestWholeWordNameWins() throws {
        let all = [weekly, call, TaskTemplate(name: "weekly", title: "W")]
        let r = try #require(TemplateQuery.resolve("/weekly review call mom", in: all))
        #expect(r.template.id == weekly.id)
        #expect(r.rest == "call mom")
    }

    @Test func resolveByFirstWordPrefixAndRest() throws {
        let r = try #require(TemplateQuery.resolve("/wee for Q4", in: [weekly, invoice]))
        #expect(r.template.id == weekly.id)
        #expect(r.rest == "for Q4")
        let exact = try #require(TemplateQuery.resolve("/call", in: [weekly, call]))
        #expect(exact.template.id == call.id && exact.rest.isEmpty)
        #expect(TemplateQuery.resolve("/nothing here", in: [weekly]) == nil)
        #expect(TemplateQuery.resolve("/", in: [weekly]) == nil)
        #expect(TemplateQuery.resolve("no slash", in: [weekly]) == nil)
    }

    // MARK: create

    @Test func createFromTemplateMakesTaskWithSubtasksInOneUndoStep() throws {
        let store = try TaskStore(inMemory: true)
        let proj = KProject(name: "Admin", colorHex: "#8B8B93", icon: "circle", area: nil, sortIndex: 0)
        store.context.insert(proj)
        var tpl = weekly
        tpl.projectName = "admin"           // name fallback, case-insensitive
        tpl.priorityRaw = KPriority.high.rawValue
        tpl.effortRaw = KEffort.m.rawValue
        tpl.estimateMinutes = 30
        let t = store.createFromTemplate(tpl, rest: "  for Q4 ")
        #expect(t.title == "Weekly review for Q4")
        #expect(t.priority == .high && t.effort == .m && t.estimateMinutes == 30)
        #expect(t.project?.id == proj.id)
        #expect(t.orderedSubtasks.map(\.title) == ["Inbox zero", "Plan next week"])
        #expect(t.dueDay == nil, "templates carry no dates")
        store.undo()
        #expect(store.task(t.id) == nil, "one undo removes the task and its steps together")
    }

    @Test func makeTemplateFromTaskCopiesStepsButNoDates() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Ship", notes: "n", dueDay: Day.today() + 2)
        store.addSubtask(t.id, title: "one")
        store.addSubtask(t.id, title: "two")
        store.update(t.id) { $0.effortRaw = KEffort.s.rawValue }
        let tpl = try #require(store.makeTemplate(from: t.id))
        #expect(tpl.title == "Ship" && tpl.name == "Ship" && tpl.subtasks == ["one", "two"])
        #expect(tpl.effortRaw == KEffort.s.rawValue && tpl.notes == "n")
        let named = try #require(store.makeTemplate(from: t.id, name: "  Release  "))
        #expect(named.name == "Release")
    }

    /// The menu flow: save a task as a template, then make a task from it (twice). Each result is a
    /// separate task carrying the template's notes and steps, and the source is untouched.
    @Test func saveThenCreateMakesIndependentCopies() throws {
        let store = try TaskStore(inMemory: true)
        let src = store.create(title: "Plan trip", notes: "pack light", dueDay: Day.today() + 3)
        store.addSubtask(src.id, title: "tickets")
        store.addSubtask(src.id, title: "hotel")
        let tpl = try #require(store.makeTemplate(from: src.id))
        let a = store.createFromTemplate(tpl, status: .todo, dueDay: nil)
        let b = store.createFromTemplate(tpl, status: .todo, dueDay: Day.today())
        #expect(Set([src.id, a.id, b.id]).count == 3)
        for t in [a, b] {
            #expect(t.title == "Plan trip" && t.notes == "pack light")
            #expect(t.orderedSubtasks.map(\.title) == ["tickets", "hotel"])
        }
        #expect(a.dueDay == nil && b.dueDay == Day.today())
        #expect(src.dueDay == Day.today() + 3 && src.orderedSubtasks.count == 2)
    }
}
