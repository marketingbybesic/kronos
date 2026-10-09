import Testing
import Foundation
@testable import KronosCore

/// release: a task and a subtask carry ANY number of attachments; each chip removes only
/// itself; the junk a broken build wrote is cleaned. Expectations are literal strings.
@MainActor
struct ContextLinkMultiTests {

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-contextlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func encodedLineIsOneLiteralLine() {
        let link = ContextLink(kind: .email, reference: "message:%3Cabc@x.com%3E", displayName: "Re: Offer | v2")
        #expect(link.encodedLine == "link://email|Re: Offer %7C v2|message:%253Cabc@x.com%253E")
        #expect(!link.encodedLine.contains("\n"))
    }

    @Test func twoAttachmentsAccumulateAndBothRoundTrip() {
        let a = ContextLink(kind: .file, reference: "bookmarkA==", displayName: "Plan.pdf")
        let b = ContextLink(kind: .email, reference: "message:%3Cid-1%3E", displayName: "Invoice")
        let text = b.appending(to: a.appending(to: "Call Alex first"))
        #expect(text == "Call Alex first\nlink://file|Plan.pdf|bookmarkA==\nlink://email|Invoice|message:%253Cid-1%253E")
        #expect(ContextLink.findAll(in: text) == [a, b])
        #expect(ContextLink.find(in: text) == a)
    }

    @Test func sameItemTwiceIsNotDuplicated() {
        let a = ContextLink(kind: .folder, reference: "bm==", displayName: "Projects")
        let once = a.appending(to: "")
        #expect(a.appending(to: once) == once)
    }

    @Test func removingOneKeepsTheOtherAndTheText() {
        let a = ContextLink(kind: .file, reference: "bookmarkA==", displayName: "Plan.pdf")
        let b = ContextLink(kind: .web, reference: "https://example.com", displayName: "Example")
        let text = b.appending(to: a.appending(to: "Notes line"))
        let after = ContextLink.removing(a, from: text)
        #expect(after == "Notes line\nlink://web|Example|https://example.com")
        #expect(ContextLink.findAll(in: after) == [b])
        // Same reference, different kind: not the same attachment.
        let other = ContextLink(kind: .folder, reference: "bookmarkA==", displayName: "Plan.pdf")
        #expect(ContextLink.removing(other, from: text) == text)
    }

    @Test func legacySingleLinkStillParses() {
        let legacy = "Kind regards\nlink://file|4.1 - CLIENT PROFILE.xlsx|Ym9vazAD"
        #expect(ContextLink.findAll(in: legacy).map(\.displayName) == ["4.1 - CLIENT PROFILE.xlsx"])
    }

    @Test func corruptLinesFromTheBrokenBuildAreStripped() {
        let junk = "\n(Self.scheme)\n(kind.rawValue)|\n(Self.escape(displayName))|\n(Self.escape(reference))"
        let notes = "Izvor: moj note" + "\n" + junk + "\n" + junk + "\nlink://file|A.pdf|bm=="
        #expect(ContextLink.strippingCorruptLines(notes) == "Izvor: moj note\n\nlink://file|A.pdf|bm==")
        #expect(ContextLink.strippingCorruptLines("Clean text\nlink://file|A.pdf|bm==") == nil)
    }

    @Test func storeStripsCorruptLinesOnlyWhereTheyAre() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("KRONOS_STORE_DIR", dir.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        let store = try TaskStore(inMemory: true)
        let bad = store.create(title: "Bad", notes: "Keep me\n(Self.scheme)\n(kind.rawValue)|\n(Self.escape(displayName))|\n(Self.escape(reference))",
                               project: nil, status: .todo, priority: .none, dueDay: nil)
        let good = store.create(title: "Good", notes: "(Self.scheme) is mentioned inline", project: nil,
                                status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth
        #expect(TaskStore.stripCorruptContextLinkLines(store: store) == 1)
        #expect(store.task(bad.id)?.notes == "Keep me")
        #expect(store.task(good.id)?.notes == "(Self.scheme) is mentioned inline")
        #expect(store.undoDepth == depth)
        #expect(TaskStore.stripCorruptContextLinkLines(store: store) == 0)
    }

    /// SD-003: marker-gated like every other launch migration — it runs once per store, not on
    /// every launch. A note that turns corrupt AFTER the marker is set is left alone: the second
    /// call skips the scan entirely rather than happening to find nothing new.
    @Test func storeScansOnlyOnceNotOnEveryLaunch() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("KRONOS_STORE_DIR", dir.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        let store = try TaskStore(inMemory: true)
        let bad1 = store.create(title: "Bad 1", notes: "Keep me\n(Self.scheme)\n(kind.rawValue)|\n(Self.escape(displayName))|\n(Self.escape(reference))",
                                project: nil, status: .todo, priority: .none, dueDay: nil)
        #expect(TaskStore.stripCorruptContextLinkLines(store: store) == 1)
        #expect(store.task(bad1.id)?.notes == "Keep me")
        let marker = dir.appendingPathComponent(TaskStore.markerRelativePath)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(store.metaValue(StoreMetaKey.corruptContextLinkLines) == "1")

        // A later launch on the same store: a fresh dirty note written after the marker was set
        // is left alone — the gate skips the scan entirely rather than finding nothing to fix.
        let bad2 = store.create(title: "Bad 2", notes: "Keep me too\n(Self.scheme)\n(kind.rawValue)|\n(Self.escape(displayName))|\n(Self.escape(reference))",
                                project: nil, status: .todo, priority: .none, dueDay: nil)
        #expect(TaskStore.stripCorruptContextLinkLines(store: store) == 0)
        #expect(store.task(bad2.id)?.notes != "Keep me too", "the gate skipped the scan: junk written after the marker is still there")
    }

    @Test func subtaskNotesHoldAttachmentsWithUndoAndSurviveExportImport() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Offer", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let s = try #require(store.addSubtask(t.id, title: "Check the sheet"))
        let a = ContextLink(kind: .file, reference: "bmA==", displayName: "Sheet.xlsx")
        let b = ContextLink(kind: .email, reference: "message:%3Cq%3E", displayName: "Question")
        store.updateSubtaskNotes(s.id, notes: a.appending(to: s.notes))
        store.updateSubtaskNotes(s.id, notes: b.appending(to: s.notes))
        #expect(ContextLink.findAll(in: s.notes) == [a, b])
        #expect(store.task(t.id)?.notes == "")           // the task's own notes untouched
        store.undo()
        #expect(ContextLink.findAll(in: s.notes) == [a])

        let data = JSONExporter(store: store).exportData()
        let fresh = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: fresh).importData(data)
        let restored = try #require(fresh.task(t.id)?.orderedSubtasks.first)
        #expect(ContextLink.findAll(in: restored.notes) == [a])
    }
}

struct FirstMoveGenericTests {
    @Test func generatorPlaceholdersAreGeneric() {
        for s in ["Open the notes for this task and write the first line",
                  "open the notes for this task and write the first move.",
                  "Otvori bilješke ovog zadatka i napiši prvu rečenicu",
                  "Open this task and read subtask 1",
                  "Open the notes and read them for 2 minutes",
                  "Write one sentence about this task in the notes"] {
            #expect(DeterministicFirstMove.isGenericTemplate(s), "\(s)")
        }
    }

    @Test func realMovesAreNotGeneric() {
        for s in ["Open Mail and start a new message to Alex.", "Call the landlord",
                  "Start by opening the invoice folder", "Review and send the Q3 deck", ""] {
            #expect(!DeterministicFirstMove.isGenericTemplate(s), "\(s)")
        }
    }
}

struct StoreDirectoryTests {
    @Test func demoBuildGetsItsOwnFolder() {
        #expect(KronosStore.folderName(bundleID: "com.besic.kronos") == "Kronos")
        #expect(KronosStore.folderName(bundleID: "com.besic.kronos.demo") == "Kronos Demo")
        #expect(KronosStore.folderName(bundleID: nil) == "Kronos")
    }
}
