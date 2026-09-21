// Kronos/Links/NoteLinkTestFixtures.swift. The fixture data LiveUITest+NoteLink.swift
// injects for its note-link click step. Split into its own file (matching the
// `*Fixtures.swift` naming `scripts/verify-hardcoded.mjs` already excuses — CaptureFixtures.swift
// is the existing precedent) so these placeholder note titles are recognised as fixture data,
// not UI prose that bypasses the localization catalog.
import KronosCore
import Foundation

enum NoteLinkTestFixtures {
    static func bridge() -> FixtureNotesBridge {
        FixtureNotesBridge(
            folders: [NoteFolderInfo(id: "f1", name: "Kronos")],
            notesByFolder: ["Kronos": [
                NoteInfo(id: "n1", title: "Acme kickoff recap", modifiedAt: Date()),
                NoteInfo(id: "n2", title: "Globex onboarding", modifiedAt: Date().addingTimeInterval(-3600)),
            ]],
            bodiesByID: ["n1": "Acme kickoff recap\nFollow up with pricing by Friday."])
    }
}
