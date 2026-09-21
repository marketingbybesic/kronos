import Testing
import Foundation
@testable import KronosCore

struct AppleNotesBridgeTests {

    @Test func notesHtmlBecomesPlainText() {
        let html = "<div>Buy milk</div><ul><li>Eggs</li><li>Bread &amp; butter</li></ul><p>Call Alex&nbsp;tomorrow</p>"
        let text = NoteHTML.plainText(from: html)
        #expect(text.contains("Buy milk"))
        #expect(text.contains("\u{2022} Eggs"))
        #expect(text.contains("\u{2022} Bread & butter"))
        #expect(text.contains("Call Alex tomorrow"))
        #expect(!text.contains("<"))
        #expect(!text.contains("&amp;"))
    }

    @Test func notesBridgeMapsNotAuthorised() {
        // Canned osascript stderr for "not authorized to send Apple events" —
        // no real Notes access, just the parser under test.
        let stderr = "execution error: Notes got an error: Not authorized to send Apple events to Notes. (-1743)"
        let mapped = NotesBridgeErrorMapper.map(stderr: stderr, status: 1)
        #expect(mapped == .notAuthorised)

        let other = NotesBridgeErrorMapper.map(stderr: "execution error: Notes got an error: some other failure.", status: 1)
        #expect(other != .notAuthorised)
    }

    // Hand-tabled: each row is a real osascript stderr string captured live, paired with the
    // ONE NotesError it must map to. -1728 ("can't get element") is a missing folder, never
    // the same UI state as -1743 (no permission) — the two must stay distinguishable so the UI
    // can tell "nothing there" from "not allowed to look".
    @Test func notesBridgeMapsNotFoundDistinctFromNotAuthorised() {
        let cases: [(stderr: String, expected: NotesError)] = [
            ("36:41: execution error: Notes got an error: Can\u{2019}t get folder \"NoSuchFolderXYZ\". (-1728)", .notFound),
            ("execution error: Notes got an error: Not authorized to send Apple events to Notes. (-1743)", .notAuthorised),
            ("execution error: Notes got an error: Application isn\u{2019}t running. (-600)", .notesAppUnavailable),
        ]
        for c in cases {
            let mapped = NotesBridgeErrorMapper.map(stderr: c.stderr, status: 1)
            #expect(mapped == c.expected, "stderr \(c.stderr) mapped to \(mapped), expected \(c.expected)")
        }
        // -1728 must never collapse into .notAuthorised or a generic failure.
        #expect(NotesBridgeErrorMapper.map(stderr: cases[0].stderr, status: 1) != .notAuthorised)
    }

    @Test func noteLinkRoundTrips() {
        let withLink = NoteLink.appending("ABC-123", to: "Some existing notes text")
        #expect(NoteLink.find(in: withLink) == "ABC-123")
        #expect(withLink.contains("Some existing notes text"))

        // Re-linking replaces rather than duplicates.
        let relinked = NoteLink.appending("XYZ-999", to: withLink)
        #expect(NoteLink.find(in: relinked) == "XYZ-999")
        #expect(relinked.components(separatedBy: "\n").filter { $0.hasPrefix("notes://") }.count == 1)
    }

    @Test func noteLinkFindReturnsNilWithoutLink() {
        #expect(NoteLink.find(in: "Just plain notes, nothing linked.") == nil)
    }

    @Test func fixtureBridgeThrowsInjectedError() async {
        let bridge = FixtureNotesBridge(errorToThrow: .notAuthorised)
        await #expect(throws: NotesError.notAuthorised) {
            _ = try await bridge.folders()
        }
    }

    @Test func fixtureBridgeReturnsStubbedFoldersAndNotes() async throws {
        let folder = NoteFolderInfo(id: "f1", name: "Kronos")
        let note = NoteInfo(id: "n1", title: "Meeting recap", modifiedAt: Date())
        let bridge = FixtureNotesBridge(folders: [folder], notesByFolder: ["Kronos": [note]],
                                        bodiesByID: ["n1": "<p>Ship it</p>"])
        let folders = try await bridge.folders()
        #expect(folders == [folder])
        let notes = try await bridge.notes(inFolder: "Kronos")
        #expect(notes == [note])
        let body = try await bridge.body(ofNoteID: "n1")
        #expect(body == "<p>Ship it</p>") // fixture returns raw stub; HTML->text is the real bridge's job
    }

    @Test func fixtureOpenRecordsNoteIDAndPropagatesError() async throws {
        let bridge = FixtureNotesBridge()
        try await bridge.open(noteID: "x-coredata://ABC/ICNote/p1")
        #expect(bridge.lastOpenedNoteID == "x-coredata://ABC/ICNote/p1")

        let failing = FixtureNotesBridge(errorToThrow: .notFound)
        await #expect(throws: NotesError.notFound) {
            try await failing.open(noteID: "missing")
        }
    }

    // `noteIDs(titled:)` is the exact-title lookup a text-only drag resolves through — one
    // match, several matches (caller picks the newest), no match.
    @Test func noteIDsTitledReturnsExactMatchesByTitle() async throws {
        let single = NoteInfo(id: "n1", title: "Meeting recap", modifiedAt: Date())
        let bridge = FixtureNotesBridge(notesByTitle: ["Meeting recap": [single]])
        let result = try await bridge.noteIDs(titled: "Meeting recap")
        #expect(result == [single])
    }

    @Test func noteIDsTitledReturnsSeveralMatchesWhenAmbiguous() async throws {
        let older = NoteInfo(id: "n1", title: "Shopping list", modifiedAt: Date(timeIntervalSince1970: 1000))
        let newer = NoteInfo(id: "n2", title: "Shopping list", modifiedAt: Date(timeIntervalSince1970: 2000))
        let bridge = FixtureNotesBridge(notesByTitle: ["Shopping list": [older, newer]])
        let result = try await bridge.noteIDs(titled: "Shopping list")
        #expect(Set(result.map(\.id)) == Set(["n1", "n2"]))
        // The caller (InspectorNotesDropZone) picks max(by: modifiedAt) — proved here directly
        // since that's plain Swift, not bridge behaviour, but the fixture must hand back BOTH
        // so that choice has something to choose from.
        #expect(result.max(by: { $0.modifiedAt < $1.modifiedAt })?.id == "n2")
    }

    @Test func noteIDsTitledReturnsEmptyForNoMatch() async throws {
        let bridge = FixtureNotesBridge(notesByTitle: ["Other title": [NoteInfo(id: "n1", title: "Other title", modifiedAt: Date())]])
        let result = try await bridge.noteIDs(titled: "Nothing has this title")
        #expect(result.isEmpty)
    }

    @Test func noteIDsTitledPropagatesInjectedError() async {
        let bridge = FixtureNotesBridge(errorToThrow: .timedOut)
        await #expect(throws: NotesError.timedOut) {
            _ = try await bridge.noteIDs(titled: "Anything")
        }
    }

    @Test func escapeForAppleScriptHandlesQuotesAndBackslashes() {
        let raw = "Sam's \"notes\" \\ folder"
        let escaped = OsaScriptNotesBridge.escapeForAppleScript(raw)
        #expect(escaped == "Sam's \\\"notes\\\" \\\\ folder")
    }

    @Test func contextLinkRoundTrips() {
        let file = ContextLink(kind: .file, reference: "base64bookmarkdata==", displayName: "Q4 | Plan.pdf")
        let withLink = file.appending(to: "Some task notes")
        let found = ContextLink.find(in: withLink)
        #expect(found?.kind == .file)
        #expect(found?.reference == "base64bookmarkdata==")
        #expect(found?.displayName == "Q4 | Plan.pdf") // pipe in the name survives escaping
        #expect(withLink.contains("Some task notes"))

        // Re-linking to a different kind replaces, never accumulates.
        let web = ContextLink(kind: .web, reference: "https://example.com/doc", displayName: "Example doc")
        let relinked = web.appending(to: withLink)
        #expect(ContextLink.find(in: relinked)?.kind == .web)
        #expect(relinked.components(separatedBy: "\n").filter { $0.hasPrefix("link://") }.count == 1)

        // A note link and a context link coexist independently on the same text.
        let withBoth = NoteLink.appending("note-1", to: relinked)
        #expect(NoteLink.find(in: withBoth) == "note-1")
        #expect(ContextLink.find(in: withBoth)?.kind == .web)
    }

    @Test func contextLinkFindReturnsNilWithoutLink() {
        #expect(ContextLink.find(in: "Nothing linked here.") == nil)
    }

    // `.folder` is its own `ContextLink.Kind` case, distinct from `.file`: without it a
    // dropped folder round-trips through `ContextLink` indistinguishably from a plain file and
    // the inspector can never choose `activateFileViewerSelecting` vs `open` correctly.
    @Test func contextLinkFolderRoundTripsDistinctFromFile() {
        let folder = ContextLink(kind: .folder, reference: "base64bookmarkdata==", displayName: "Projects")
        let withLink = folder.appending(to: "Some task notes")
        let found = ContextLink.find(in: withLink)
        #expect(found?.kind == .folder)
        #expect(found?.kind != .file)
        #expect(found?.reference == "base64bookmarkdata==")
        #expect(found?.displayName == "Projects")
    }
}
