import Testing
import Foundation
@testable import KronosCore

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_790_000_000)
private func entry(_ name: String, daysAgo: Double) -> BackupPolicy.Entry {
    BackupPolicy.Entry(name: name, date: now.addingTimeInterval(-daysAgo * day))
}
/// n = 1...20 -> kronos-2026-09-01 ... (sorts by date)
private func dailyName(_ n: Int, ext: String) -> String {
    "kronos-2026-09-" + String(format: "%02d", n) + "." + ext
}

struct BackupPolicyPruneTests {

    @Test func dailyFilesKeepTheNewestFourteenPerExtension() {
        var files: [BackupPolicy.Entry] = []
        for n in 1...16 {
            files.append(entry(dailyName(n, ext: "json"), daysAgo: Double(17 - n)))
            files.append(entry(dailyName(n, ext: "store"), daysAgo: Double(17 - n)))
        }
        let victims = Set(BackupPolicy.pruneVictims(files, now: now))
        // Oldest two of each extension go; 14 stay.
        #expect(victims == [dailyName(1, ext: "json"), dailyName(2, ext: "json"),
                            dailyName(1, ext: "store"), dailyName(2, ext: "store")])
    }

    @Test func rollingCopyIsNeverAVictim() {
        var files = [entry(BackupPolicy.rollingStoreName, daysAgo: 400)]
        for n in 1...20 { files.append(entry(dailyName(n, ext: "store"), daysAgo: Double(21 - n))) }
        let victims = BackupPolicy.pruneVictims(files, now: now)
        #expect(!victims.contains(BackupPolicy.rollingStoreName))
        #expect(victims.count == 6)
    }

    @Test func safetyFilesGoByAgeButTheNewestThreeStay() {
        // Five pre-import files aged 1, 5, 40, 50, 60 days. The newest three stay whatever their age;
        // of the rest, those older than 30 days go.
        let files = [
            entry("pre-import-a.json", daysAgo: 1),
            entry("pre-import-b.json", daysAgo: 5),
            entry("pre-import-c.json", daysAgo: 40),
            entry("pre-import-d.json", daysAgo: 50),
            entry("pre-import-e.json", daysAgo: 60),
        ]
        #expect(Set(BackupPolicy.pruneVictims(files, now: now)) == ["pre-import-d.json", "pre-import-e.json"])
    }

    @Test func safetyFilesYoungerThanThirtyDaysStayEvenBeyondThree() {
        let files = (1...6).map { entry("crash-\($0).store", daysAgo: Double($0) * 4) }   // 4...24 days
        #expect(BackupPolicy.pruneVictims(files, now: now).isEmpty)
    }

    @Test func eachPrefixIsCountedOnItsOwn() {
        // One 100-day-old file per prefix: each is the newest of its own prefix, so none goes.
        let files = BackupPolicy.safetyPrefixes.map { entry($0 + "x.json", daysAgo: 100) }
        #expect(BackupPolicy.pruneVictims(files, now: now).isEmpty)
    }

    @Test func staleInterruptedSnapshotIsRemovedFreshOneIsNot() {
        let files = [entry("kronos-today.store.partial", daysAgo: 3), entry("kronos-2026-09-30.store.partial", daysAgo: 0.1)]
        #expect(BackupPolicy.pruneVictims(files, now: now) == ["kronos-today.store.partial"])
    }

    @Test func clockBehindTurnsAgeRulesOffButNotTheDailyCount() {
        // A file dated 10 days AFTER "now": the clock is behind. Age victims would be wrong, so none.
        var files = [
            entry("pre-import-a.json", daysAgo: 1), entry("pre-import-b.json", daysAgo: 2),
            entry("pre-import-c.json", daysAgo: 3), entry("pre-import-d.json", daysAgo: 90),
            entry("kronos-today.store.partial", daysAgo: 5),
            entry("future.json", daysAgo: -10),
        ]
        #expect(BackupPolicy.pruneVictims(files, now: now).isEmpty)
        // Control: the same folder with a correct clock does prune the 90-day file and the partial.
        files.removeLast()
        #expect(Set(BackupPolicy.pruneVictims(files, now: now)) == ["pre-import-d.json", "kronos-today.store.partial"])
        // The daily count rule goes by file name, so it still applies with the clock behind.
        var many = (1...16).map { entry(dailyName($0, ext: "json"), daysAgo: Double(17 - $0)) }
        many.append(entry("future.json", daysAgo: -10))
        #expect(Set(BackupPolicy.pruneVictims(many, now: now)) == [dailyName(1, ext: "json"), dailyName(2, ext: "json")])
    }

    @Test func dailyNameRecognition() {
        #expect(BackupPolicy.isDaily("kronos-2026-10-02.json"))
        #expect(BackupPolicy.isDaily("kronos-2026-10-02.store"))
        #expect(!BackupPolicy.isDaily("kronos-today.store"))
        #expect(!BackupPolicy.isDaily("kronos-2026-10-02.store.partial"))
        #expect(!BackupPolicy.isDaily("pre-import-2026-10-02.json"))
    }
}

struct BackupPolicyClockTests {

    @Test func rollingCopyDueTable() {
        let cases: [(last: Date?, at: TimeInterval, force: Bool, due: Bool)] = [
            (nil, 0, false, true),            // never taken
            (now, 10, false, false),          // 10 s later: too soon
            (now, 299, false, false),         // just under 5 min
            (now, 300, false, true),          // 5 min
            (now, 10, true, true),            // quit forces it
            (now, -60, false, true),          // clock moved back: take it
        ]
        for c in cases {
            #expect(BackupPolicy.rollingDue(last: c.last, now: now.addingTimeInterval(c.at), force: c.force) == c.due)
        }
    }

    @Test func lastBackupStatusTable() {
        let cases: [(last: Date?, expected: BackupPolicy.LastBackup)] = [
            (nil, .never),
            (now, .recent(secondsAgo: 0)),
            (now.addingTimeInterval(-3_600), .recent(secondsAgo: 3_600)),
            (now.addingTimeInterval(-(3 * day - 1)), .recent(secondsAgo: 3 * day - 1)),
            (now.addingTimeInterval(-3 * day), .stale(daysAgo: 3)),
            (now.addingTimeInterval(-10.5 * day), .stale(daysAgo: 10)),
            (now.addingTimeInterval(5 * day), .recent(secondsAgo: 0)),    // stamp in the future (clock behind): never "stale"
        ]
        for c in cases { #expect(BackupPolicy.lastBackup(c.last, now: now) == c.expected) }
    }
}
