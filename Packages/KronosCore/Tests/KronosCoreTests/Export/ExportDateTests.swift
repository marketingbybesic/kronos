import Testing
import Foundation
@testable import KronosCore

/// Export dates carry milliseconds; older files (whole seconds) and offset forms still read.
@MainActor
struct ExportDateTests {

    private func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    @Test func millisecondsSurviveAnExportImportRoundTrip() throws {
        let created = Date(timeIntervalSince1970: 1_790_000_000.123)
        let updated = Date(timeIntervalSince1970: 1_790_000_000.987)
        let source = try TaskStore(inMemory: true)
        let task = source.create(title: "Roundtrip", project: nil)
        task.createdAt = created
        task.updatedAt = updated
        source.saveContext()

        let data = try KronosExportCodec.makeEncoder().encode(JSONExporter(store: source).makeEnvelope())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"createdAt\" : \"2026-09-21T14:13:20.123Z\""))

        let target = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: target).importData(data, mode: .replace)
        let back = try #require(target.allTasks().first { $0.title == "Roundtrip" })
        #expect(ms(back.createdAt) == 1_790_000_000_123)
        #expect(ms(back.updatedAt) == 1_790_000_000_987)
        #expect(abs(back.createdAt.timeIntervalSince(created)) < 0.0005)

        // Control: the old whole-second strategy loses the fraction, so this test can fail.
        let wholeSecond = JSONEncoder()
        wholeSecond.dateEncodingStrategy = .iso8601
        let plain = try wholeSecond.encode([created])
        #expect(!String(decoding: plain, as: UTF8.self).contains(".123"))
    }

    @Test func fileWithWholeSecondDatesStillImports() throws {
        let source = try TaskStore(inMemory: true)
        let task = source.create(title: "Old file", project: nil)
        task.createdAt = Date(timeIntervalSince1970: 1_700_000_000.5)
        task.updatedAt = Date(timeIntervalSince1970: 1_700_000_000.5)
        source.saveContext()
        let current = String(decoding: try KronosExportCodec.makeEncoder()
            .encode(JSONExporter(store: source).makeEnvelope()), as: UTF8.self)
        #expect(current.contains(".500Z"))
        // What an older build wrote: no fraction anywhere.
        let old = current.replacingOccurrences(of: #"\.\d{3}Z"#, with: "Z", options: .regularExpression)
        #expect(!old.contains(".500Z"))

        let target = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: target).importData(Data(old.utf8), mode: .replace)
        let back = try #require(target.allTasks().first { $0.title == "Old file" })
        #expect(ms(back.createdAt) == 1_700_000_000_000)
    }

    @Test func parsesTheFormsFilesCarry() {
        // 2023-11-14T22:13:20Z is 1_700_000_000 (hand-computed).
        #expect(ExportDate.date(from: "2023-11-14T22:13:20Z").map(ms) == 1_700_000_000_000)
        #expect(ExportDate.date(from: "2023-11-14T22:13:20.250Z").map(ms) == 1_700_000_000_250)
        #expect(ExportDate.date(from: "2023-11-15T00:13:20+02:00").map(ms) == 1_700_000_000_000)
        #expect(ExportDate.date(from: "2023-11-15T00:13:20.250+02:00").map(ms) == 1_700_000_000_250)
        #expect(ExportDate.date(from: "yesterday") == nil)
        #expect(ExportDate.date(from: "") == nil)
    }

    @Test func writesUTCWithThreeFractionDigits() {
        #expect(ExportDate.string(from: Date(timeIntervalSince1970: 1_700_000_000.25)) == "2023-11-14T22:13:20.250Z")
        #expect(ExportDate.string(from: Date(timeIntervalSince1970: 1_700_000_000)) == "2023-11-14T22:13:20.000Z")
    }
}
