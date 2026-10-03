// plannedDay and carryCount through export and import.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct PlannedDayExportTests {
    static let today = Day.parseISO("2026-10-10") ?? 0

    private func populated() throws -> (TaskStore, planned: UUID, carried: UUID, plain: UUID) {
        let store = try TaskStore(inMemory: true)
        let planned = store.create(title: "planned", status: .todo, dueDay: nil)
        store.updateNoUndo(planned.id) { $0.plannedDay = Self.today + 2 }
        let carried = store.create(title: "carried", status: .todo, dueDay: Self.today - 3)
        store.updateNoUndo(carried.id) { $0.carryCount = 3; $0.dread = true }
        let plain = store.create(title: "plain", status: .todo, dueDay: nil)
        return (store, planned.id, carried.id, plain.id)
    }

    @Test func plannedDayAndCarryRoundTripThroughANewStore() throws {
        let (store, planned, carried, plain) = try populated()
        let data = JSONExporter(store: store).exportData()
        let other = try TaskStore(inMemory: true)
        try KronosImporter(store: other).importData(data, mode: .replace)
        #expect(other.task(planned)?.plannedDay == Self.today + 2)
        #expect(other.task(planned)?.dueDay == nil, "a plan is not a deadline after the round trip either")
        #expect(other.task(carried)?.carryCount == 3)
        #expect(other.task(carried)?.plannedDay == nil)
        #expect(other.task(plain)?.plannedDay == nil)
        #expect(other.task(plain)?.carryCount == 0)
    }

    @Test func exportWipeImportExportIsByteIdenticalWithPlannedTasks() throws {
        let (store, _, _, _) = try populated()
        let exporter = JSONExporter(store: store)
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        var first = exporter.makeEnvelope(now: now)
        first.exportedAt = Date(timeIntervalSince1970: 0)
        let firstData = try KronosExportCodec.makeEncoder().encode(first)
        _ = KronosImporter(store: store).importEnvelope(first, mode: .replace)
        var second = exporter.makeEnvelope(now: now)
        second.exportedAt = Date(timeIntervalSince1970: 0)
        let secondData = try KronosExportCodec.makeEncoder().encode(second)
        #expect(firstData == secondData)
        #expect(first.tasks.contains { $0.plannedDay != nil }, "the payload really carries a planned day")
        #expect(first.tasks.contains { $0.carryCount == 3 })
    }

    @Test func plannedDayIsWrittenAsAnIsoDayAndAbsentWhenUnplanned() throws {
        let (store, planned, _, plain) = try populated()
        let env = JSONExporter(store: store).makeEnvelope()
        #expect(env.tasks.first { $0.id == planned }?.plannedDay == "2026-10-12")
        #expect(env.tasks.first { $0.id == plain }?.plannedDay == nil)
        #expect(env.tasks.first { $0.id == plain }?.carryCount == nil, "zero carry is not written")
        let text = String(decoding: JSONExporter(store: store).exportData(), as: UTF8.self)
        #expect(text.contains("\"plannedDay\" : \"2026-10-12\""))
    }

    @Test func aFileWithoutTheNewKeysStillImportsWithDefaults() throws {
        let (store, planned, _, _) = try populated()
        var envelope = JSONExporter(store: store).makeEnvelope()
        for i in envelope.tasks.indices { envelope.tasks[i].plannedDay = nil; envelope.tasks[i].carryCount = nil }
        let data = try KronosExportCodec.makeEncoder().encode(envelope)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("plannedDay") && !text.contains("carryCount"), "this is an old-format file")
        let other = try TaskStore(inMemory: true)
        try KronosImporter(store: other).importData(data, mode: .replace)
        #expect(other.task(planned)?.plannedDay == nil)
        #expect(other.task(planned)?.carryCount == 0)
    }
}
