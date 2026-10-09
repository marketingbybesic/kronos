import Testing
import Foundation
@testable import KronosCore

/// Imports the real repo seed (seed/kronos-seed.json — a real Linear workspace export)
/// into an in-memory store and checks the import is exact and idempotent. Counts come from
/// the JSON file itself, never hard-coded, because Linear content changes over time.
@MainActor
struct RealSeedImportTests {
    /// Walk up from this source file to the repo root (the directory that
    /// contains "seed/kronos-seed.json"), so the test works regardless of
    /// scratch-path or working directory. `seed/kronos-seed.json` holds Alex's real
    /// company/client names and is deliberately NEVER shipped in the public export
    /// (`scripts/private/export-public.mjs`'s `NEVER` list) — a public clone has nothing
    /// to import here, so every test below skips (returns, not fails) when it's absent.
    private static func repoSeedURL() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("seed/kronos-seed.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func loadSeedData() throws -> (data: Data, file: SeedFile)? {
        guard let url = repoSeedURL() else { return nil }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(SeedFile.self, from: data)
        return (data, file)
    }

    @Test func importsRealSeedWithMatchingCounts() throws {
        guard let (data, file) = try Self.loadSeedData() else { return }
        let store = try TaskStore(inMemory: true)
        let importer = JSONImporter(store: store)

        let result = try importer.importJSON(data)

        #expect(result.tasks == file.tasks.count)
        #expect(result.projects == file.projects.count)
        #expect(result.areas == file.areas.count)
        #expect(store.allTasks().count == file.tasks.count)
    }

    @Test func secondImportIsIdempotentWithNoDuplicateExternalIDs() throws {
        guard let (data, file) = try Self.loadSeedData() else { return }
        let store = try TaskStore(inMemory: true)
        let importer = JSONImporter(store: store)

        _ = try importer.importJSON(data)
        let countAfterFirst = store.allTasks().count

        let second = try importer.importJSON(data)
        #expect(second.tasks == 0)
        #expect(second.duplicates == file.tasks.count)
        #expect(store.allTasks().count == countAfterFirst)

        let externalIDs = store.allTasks().compactMap(\.externalID)
        #expect(Set(externalIDs).count == externalIDs.count)
    }

    @Test func noImportedTaskDroppedForBeingUntriaged() throws {
        guard let (data, file) = try Self.loadSeedData() else { return }
        let store = try TaskStore(inMemory: true)
        let importer = JSONImporter(store: store)

        _ = try importer.importJSON(data)

        let expectedExternalIDs = Set(file.tasks.compactMap(\.externalID))
        let importedExternalIDs = Set(store.allTasks().compactMap(\.externalID))
        #expect(importedExternalIDs == expectedExternalIDs)
    }
}
