import Testing
import Foundation
@testable import KronosCore

/// Opt-in live test against the real Notes.app on this Mac. Skipped unless
/// `KRONOS_LIVE_NOTES=1` is set, so CI and every ordinary `swift test` run
/// never touches Notes or triggers the Automation consent prompt. Prints
/// folder COUNT only — never a folder name or any note content.
struct LiveNotesTests {
    @Test func liveNotesListsFolders() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_NOTES"] == "1" else {
            print("SKIPPED: set KRONOS_LIVE_NOTES=1 to run against real Notes.app")
            return
        }
        let bridge = OsaScriptNotesBridge()
        do {
            let folders = try await bridge.folders()
            print("Notes folders found: \(folders.count)")
        } catch let error as NotesError where error == .notAuthorised {
            print("notAuthorised: Automation access to Notes has not been granted")
        }
    }

    /// Reproduces a real bug: an iCloud folder named "Kronos" with one note exists, but "Test
    /// access" reported "Folders found: 0". This proves the fix end to end through the real
    /// osascript process, not a fixture — if `folders()` regresses to its old comma-joined-line
    /// parsing, this fails again exactly like the live app did.
    @Test func liveNotesFindsTheKronosFolderByName() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_NOTES"] == "1" else {
            print("SKIPPED: set KRONOS_LIVE_NOTES=1 to run against real Notes.app")
            return
        }
        let bridge = OsaScriptNotesBridge()
        do {
            let folders = try await bridge.folders()
            #expect(folders.count > 0)
            let hasKronos = folders.contains { $0.name == "Kronos" }
            print("Notes folders found: \(folders.count), has Kronos folder: \(hasKronos)")
        } catch let error as NotesError where error == .notAuthorised {
            print("notAuthorised: Automation access to Notes has not been granted")
        }
    }

    /// `notes(inFolder:)` against a folder name that does not exist must throw `.notFound`,
    /// never `.unexpected` and never an empty array — the same "no such folder" vs. "no
    /// permission" distinction, proven against the real osascript error text this time (not
    /// the canned stderr `notesBridgeMapsNotFoundDistinctFromNotAuthorised` already checks
    /// offline).
    @Test func liveNotesInFolderThrowsNotFoundForMissingFolder() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_NOTES"] == "1" else {
            print("SKIPPED: set KRONOS_LIVE_NOTES=1 to run against real Notes.app")
            return
        }
        let bridge = OsaScriptNotesBridge()
        do {
            _ = try await bridge.notes(inFolder: "ThisFolderDoesNotExist-Kronos-Test")
            Issue.record("expected .notFound, got a result")
        } catch let error as NotesError {
            #expect(error == .notFound, "expected .notFound, got \(error)")
        }
    }
}
