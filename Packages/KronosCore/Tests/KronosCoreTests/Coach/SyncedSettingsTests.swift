import Testing
import Foundation
@testable import KronosCore

private func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let suite = "kronos.test.syncedsettings.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    return (d, { d.removePersistentDomain(forName: suite) })
}

private func date(_ day: Int, _ hour: Int = 12) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
}

struct SyncedSettingsFieldTests {
    // Every field of CoachSettings is classified. A new field fails this test until someone
    // decides whether it syncs.
    @Test func everyCoachSettingsFieldIsClassified() {
        let labels = Set(Mirror(reflecting: CoachSettings()).children.compactMap(\.label))
        let classified = SyncedCoachSettings.syncedFields.union(SyncedCoachSettings.deviceLocalFields)
        #expect(labels == classified, "unclassified: \(labels.subtracting(classified)), stale: \(classified.subtracting(labels))")
        #expect(SyncedCoachSettings.syncedFields.isDisjoint(with: SyncedCoachSettings.deviceLocalFields))
    }

    @Test func appliedReplacesSyncedFieldsAndKeepsDeviceLocalOnes() {
        let folder = ProjectFolderLink.finder(bookmark: Data([1, 2, 3]), displayPath: "/home/me/Work")
        var local = CoachSettings()
        local.projectFolders = [UUID(): [folder]]
        local.density = "regular"
        local.accentHex = nil
        var remote = CoachSettings()
        remote.density = "compact"
        remote.accentHex = "#b483ff"
        remote.blockLeadMinutes = 12
        remote.notesInboxFolder = "Inbox"
        let merged = SyncedCoachSettings(from: remote, updatedAt: date(3)).applied(to: local)
        #expect(merged.density == "compact")
        #expect(merged.accentHex == "#b483ff")
        #expect(merged.blockLeadMinutes == 12)
        #expect(merged.notesInboxFolder == "Inbox")
        #expect(merged.projectFolders == local.projectFolders)
    }
}

@MainActor
struct SettingsSyncTests {
    @Test func disabledByDefaultWritesNothing() {
        let kvs = FixtureSettingsKVS()
        let sync = SettingsSync(kvs: kvs)
        var s = CoachSettings()
        s.density = "compact"
        #expect(sync.push(s, now: date(3)) == false)
        #expect(kvs.syncedData(forKey: SettingsSync.key) == nil)
    }

    @Test func enabledPushWritesOnceAndIdenticalValuesDoNotEcho() {
        let kvs = FixtureSettingsKVS()
        let sync = SettingsSync(kvs: kvs, isEnabled: { true })
        var s = CoachSettings()
        s.density = "compact"
        #expect(sync.push(s, now: date(3)) == true)
        #expect(sync.push(s, now: date(4)) == false)
        s.textSize = "L"
        #expect(sync.push(s, now: date(5)) == true)
    }

    @Test func deviceLocalFieldsNeverReachTheStore() throws {
        let kvs = FixtureSettingsKVS()
        let sync = SettingsSync(kvs: kvs, isEnabled: { true })
        var s = CoachSettings()
        s.projectFolders = [UUID(): [ProjectFolderLink.finder(bookmark: Data("SECRETBOOKMARK".utf8), displayPath: "/home/me/Private")]]
        sync.push(s, now: date(3))
        let json = String(decoding: try #require(kvs.syncedData(forKey: SettingsSync.key)), as: UTF8.self)
        #expect(!json.contains("projectFolders"))
        #expect(!json.contains("/home/me/Private"))
        #expect(json.contains("\"density\""))   // positive control: synced fields are present
    }

    @Test func aSecondDeviceAdoptsTheSyncedFieldsAndKeepsItsOwnDeviceLocalData() {
        let (d1, clean1) = isolatedDefaults(); defer { clean1() }
        let (d2, clean2) = isolatedDefaults(); defer { clean2() }
        let kvs = FixtureSettingsKVS()
        let mac = CoachSettingsStore(defaults: d1, sync: SettingsSync(kvs: kvs, isEnabled: { true }))
        let phone = CoachSettingsStore(defaults: d2, sync: SettingsSync(kvs: kvs, isEnabled: { true }))

        var s = mac.load()
        s.density = "compact"
        s.projectFolders = [UUID(): [ProjectFolderLink.appleNotes(folderName: "Mac only")]]
        mac.save(s)

        let phoneFolders = [UUID(): [ProjectFolderLink.appleNotes(folderName: "Phone only")]]
        var p = phone.load()
        p.projectFolders = phoneFolders
        // Written straight to defaults: a local-only change, not a synced one, so it must not
        // look newer than the Mac's save.
        d2.set(try! JSONEncoder().encode(p), forKey: "kronos.coach.settings.v1")

        #expect(phone.applyRemote() == true)
        #expect(phone.load().density == "compact")
        #expect(phone.load().projectFolders == phoneFolders)
        // Positive control: before applyRemote the phone still had the default.
        #expect(CoachSettings().density == "regular")
    }

    @Test func remoteOlderThanLocalIsIgnoredAndNewerIsTaken() {
        let (d, clean) = isolatedDefaults(); defer { clean() }
        let kvs = FixtureSettingsKVS()
        let sync = SettingsSync(kvs: kvs, isEnabled: { true })
        var remote = CoachSettings()
        remote.textSize = "XL"
        sync.push(remote, now: date(2))   // written on day 2

        let store = CoachSettingsStore(defaults: d, sync: sync)
        #expect(sync.newerRemote(than: date(3)) == nil)       // local changed after: ignored
        #expect(sync.newerRemote(than: date(1))?.textSize == "XL")
        #expect(sync.newerRemote(than: nil)?.textSize == "XL")
        #expect(store.applyRemote() == true)
        #expect(store.load().textSize == "XL")
        #expect(store.applyRemote() == false)                  // already adopted, nothing newer
    }

    @Test func disabledSyncNeverAppliesRemote() {
        let (d, clean) = isolatedDefaults(); defer { clean() }
        let kvs = FixtureSettingsKVS()
        var remote = CoachSettings()
        remote.textSize = "XL"
        SettingsSync(kvs: kvs, isEnabled: { true }).push(remote, now: date(2))
        let store = CoachSettingsStore(defaults: d, sync: SettingsSync(kvs: kvs))   // flag off
        #expect(store.applyRemote() == false)
        #expect(store.load().textSize == "M")
    }

    @Test func flagReadsDefaults() {
        let (d, clean) = isolatedDefaults(); defer { clean() }
        let flag = SettingsSync.flag(in: d)
        #expect(flag() == false)
        d.set(true, forKey: SettingsSync.flagKey)
        #expect(flag() == true)
    }
}

struct SchemaGuardTests {
    // Hand-written table: (build, recorded minimums) -> mode.
    @Test func modeTable() {
        #expect(SchemaGuard.mode(build: 2, minimums: []) == .readWrite)
        #expect(SchemaGuard.mode(build: 2, minimums: [nil, nil]) == .readWrite)
        #expect(SchemaGuard.mode(build: 2, minimums: [2]) == .readWrite)
        #expect(SchemaGuard.mode(build: 3, minimums: [2]) == .readWrite)
        #expect(SchemaGuard.mode(build: 2, minimums: [3]) == .readOnly(requires: 3))
        #expect(SchemaGuard.mode(build: 2, minimums: [nil, 3, 2]) == .readOnly(requires: 3))
        #expect(SchemaGuard.mode(build: 1, minimums: [2]) == .readOnly(requires: 2))
    }

    // The old-build story end to end: a newer build records 3 in the store; an older build
    // (schema 2) reads it and goes read-only; the newer build itself stays writable.
    @Test func olderBuildGoesReadOnlyAfterANewerBuildRecordsItsSchema() {
        let kvs = FixtureSettingsKVS()
        #expect(SchemaGuard.mode(build: 2, minimums: [SchemaGuard.minimum(in: kvs)]) == .readWrite)
        #expect(SchemaGuard.raiseMinimum(to: 3, in: kvs) == true)
        #expect(SchemaGuard.mode(build: 2, minimums: [SchemaGuard.minimum(in: kvs)]) == .readOnly(requires: 3))
        #expect(SchemaGuard.mode(build: 3, minimums: [SchemaGuard.minimum(in: kvs)]) == .readWrite)
    }

    @Test func minimumOnlyRises() {
        let kvs = FixtureSettingsKVS()
        #expect(SchemaGuard.raiseMinimum(to: 3, in: kvs) == true)
        #expect(SchemaGuard.raiseMinimum(to: 2, in: kvs) == false)
        #expect(SchemaGuard.raiseMinimum(to: 3, in: kvs) == false)
        #expect(SchemaGuard.minimum(in: kvs) == 3)
        #expect(SchemaGuard.raiseMinimum(to: 4, in: kvs) == true)
    }

    // Keeps the constant honest: it must follow the real schema.
    @Test func buildVersionMatchesTheRealSchema() {
        #expect(SchemaGuard.currentBuildVersion == KronosSchemaV2.versionIdentifier.major)
    }
}
