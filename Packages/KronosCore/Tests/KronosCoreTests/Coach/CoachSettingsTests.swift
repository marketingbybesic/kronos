import Testing
import Foundation
@testable import KronosCore

@MainActor
struct CoachSettingsTests {

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = "kronos.coach.tests.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func coachSettingsSurviveReload() {
        let defaults = isolatedDefaults("reload")
        let store = CoachSettingsStore(defaults: defaults)

        var settings = CoachSettings()
        settings.autoTriage = false
        settings.blockLeadMinutes = 12
        settings.notesInboxFolder = "Inbox Notes"
        settings.triageMayFill = [.priority, .deadline]
        settings.presets.append(OrdoPreset(id: "custom-9", name: "Nine", sort: [.asc(.title)]))
        // UUID-keyed dictionary: not natively a JSON object key, so this is
        // the field most likely to silently fail to round-trip.
        let projectID = UUID()
        settings.calendarKeywords = [projectID: ["Acme", "AC"]]
        store.save(settings)

        // A second store instance over the same defaults must see exactly
        // what was saved — this is the persistence contract, not the
        // in-memory struct's own equality.
        let reloaded = CoachSettingsStore(defaults: defaults).load()
        #expect(reloaded == settings)
        #expect(reloaded.autoTriage == false)
        #expect(reloaded.blockLeadMinutes == 12)
        #expect(reloaded.notesInboxFolder == "Inbox Notes")
        #expect(reloaded.triageMayFill == [.priority, .deadline])
        #expect(reloaded.presets.contains { $0.id == "custom-9" })
        #expect(reloaded.calendarKeywords[projectID] == ["Acme", "AC"])
    }

    @Test func coachSettingsLoadWithoutSaveReturnsDefaults() {
        let defaults = isolatedDefaults("fresh")
        let store = CoachSettingsStore(defaults: defaults)
        let settings = store.load()
        #expect(settings.autoTriage == true)
        #expect(settings.presets.map(\.id) == OrdoPreset.builtIns.map(\.id))
    }

    @Test func projectFolderLinksSurviveReload() {
        let defaults = isolatedDefaults("folders")
        let store = CoachSettingsStore(defaults: defaults)

        let projectID = UUID()
        let bookmark = Data("fake-bookmark-bytes".utf8)
        var settings = CoachSettings()
        settings.projectFolders[projectID] = [
            .appleNotes(folderName: "Acme"),
            .finder(bookmark: bookmark, displayPath: "~/Documents/Acme"),
        ]
        store.save(settings)

        let reloaded = CoachSettingsStore(defaults: defaults).load()
        let links = reloaded.projectFolders[projectID]
        #expect(links?.count == 2)
        #expect(links?.first { $0.kind == .appleNotesFolder }?.notesFolderName == "Acme")
        let finderLink = links?.first { $0.kind == .finderFolder }
        #expect(finderLink?.folderBookmark == bookmark)
        #expect(finderLink?.displayPath == "~/Documents/Acme")
    }

    @Test func learnRecordsFoldedEventTitle() {
        var settings = CoachSettings()
        let projectID = UUID()
        settings.learn(eventTitle: "ÄCME Sync", projectID: projectID)
        #expect(settings.learnedEventTitles[KTextFold.fold("acme sync")] == projectID)
    }
}
