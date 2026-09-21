import Testing
import Foundation
@testable import KronosCore

/// `KProject.icon` is `String?` (nil = plain colour dot), per SPEC §12.8. Covers the
/// export/import round trip, the undo step `updateProject(icon:)` joins, an older file
/// importing with icon nil, and the seed's 10 projects each carrying a real icon name.
@MainActor
struct ProjectIconTests {

    // MARK: - projectIconRoundTripsThroughExport

    @Test func projectIconRoundTripsThroughExport() throws {
        let store = try TaskStore(inMemory: true)
        store.createProject(name: "Acme", colorHex: "#3FB950", icon: "utensils")
        let withoutIcon = store.createProject(name: "Inbox", colorHex: "#8224E3")
        #expect(withoutIcon.icon == nil)

        let envelope = JSONExporter(store: store).makeEnvelope()
        let exportedWithIcon = try #require(envelope.projects.first { $0.name == "Acme" })
        let exportedWithoutIcon = try #require(envelope.projects.first { $0.name == "Inbox" })
        #expect(exportedWithIcon.icon == "utensils")
        #expect(exportedWithoutIcon.icon == nil)

        // Round-trip through a fresh store: the icon (and its absence) survives.
        let store2 = try TaskStore(inMemory: true)
        _ = KronosImporter(store: store2).importEnvelope(envelope, mode: .replace)
        let importedWithIcon = try #require(store2.allProjects().first { $0.name == "Acme" })
        let importedWithoutIcon = try #require(store2.allProjects().first { $0.name == "Inbox" })
        #expect(importedWithIcon.icon == "utensils")
        #expect(importedWithoutIcon.icon == nil)
    }

    // MARK: - projectIconChangeIsOneUndoStep

    @Test func projectIconChangeIsOneUndoStep() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createProject(name: "Globex", colorHex: "#8224E3")
        #expect(p.icon == nil)

        let depth = store.undoDepth
        store.updateProject(p.id, icon: .some("wallet"))
        #expect(p.icon == "wallet")
        #expect(store.undoDepth == depth + 1)

        store.undo()
        #expect(p.icon == nil)
        store.redo()
        #expect(p.icon == "wallet")

        // Clearing back to the dot is `.some(nil)`, the same one-step shape
        // (checked right after the mutation, like every sibling test here —
        // `redo()` replays a step without re-arming undo depth, so depth is
        // asserted immediately after a direct call, not across undo/redo).
        let depthBeforeClear = store.undoDepth
        store.updateProject(p.id, icon: .some(nil))
        #expect(p.icon == nil)
        #expect(store.undoDepth == depthBeforeClear + 1)

        // A no-op edit (icon already "wallet" restated) pushes nothing.
        store.updateProject(p.id, icon: .some("wallet"))
        let quietDepth = store.undoDepth
        store.updateProject(p.id, icon: .some("wallet"))
        #expect(store.undoDepth == quietDepth)

        // Leaving `icon` unset (bare nil) alongside another field change
        // must not disturb the icon already on the row.
        store.updateProject(p.id, name: "Globex Capital")
        #expect(p.icon == "wallet")
        #expect(p.name == "Globex Capital")
    }

    // MARK: - importWithoutIconLeavesNil

    @Test func importWithoutIconLeavesNil() throws {
        // An older v1 envelope: no "icon" key on the project at all.
        let projectID = UUID()
        let json = """
        {
          "format": "kronos",
          "version": 1,
          "exportedAt": "2026-01-01T00:00:00Z",
          "areas": [],
          "projects": [
            { "id": "\(projectID.uuidString)", "name": "Legacy", "colorHex": "#8224E3",
              "sortIndex": 0, "isArchived": false, "areaID": null,
              "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z" }
          ],
          "labels": [],
          "rules": [],
          "savedViews": [],
          "tasks": []
        }
        """
        let store = try TaskStore(inMemory: true)
        let importer = KronosImporter(store: store)
        let result = try importer.importData(Data(json.utf8), mode: .replace)

        #expect(result.projects == 1)
        let project = try #require(store.allProjects().first)
        #expect(project.icon == nil)

        // Explicit JSON `null` for icon must also leave it nil, not decode-fail.
        let projectID2 = UUID()
        let jsonWithNull = """
        {
          "format": "kronos",
          "version": 1,
          "exportedAt": "2026-01-01T00:00:00Z",
          "areas": [],
          "projects": [
            { "id": "\(projectID2.uuidString)", "name": "LegacyNull", "colorHex": "#8224E3",
              "icon": null, "sortIndex": 0, "isArchived": false, "areaID": null,
              "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z" }
          ],
          "labels": [],
          "rules": [],
          "savedViews": [],
          "tasks": []
        }
        """
        let result2 = try importer.importData(Data(jsonWithNull.utf8), mode: .merge)
        #expect(result2.projects == 1)
        let project2 = try #require(store.allProjects().first { $0.name == "LegacyNull" })
        #expect(project2.icon == nil)
    }

    // MARK: - seedProjectsAllHaveIcons

    /// The curated names the seed generator is allowed to assign: the design system's picker
    /// grid maps exactly these.
    private static let curatedSeedIcons: Set<String> = [
        "briefcase", "building", "utensils", "camera", "tooth", "car",
        "stethoscope", "landmark", "megaphone", "pen-tool", "rocket",
        "globe", "wallet", "users", "graduation-cap",
    ]

    private static func repoSeedURL() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("seed/kronos-seed.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("seed/kronos-seed.json not found by walking up from \(#filePath)")
    }

    @Test func seedProjectsAllHaveIcons() throws {
        let url = Self.repoSeedURL()
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(SeedFile.self, from: data)

        #expect(!file.projects.isEmpty)
        for p in file.projects {
            #expect(
                Self.curatedSeedIcons.contains(p.icon),
                "project \(p.name) has icon \"\(p.icon)\", not in the curated seed set"
            )
        }
    }
}
