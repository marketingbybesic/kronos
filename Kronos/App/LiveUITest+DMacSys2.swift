// Live steps for the launch wiring: schema guard at store open, seeding decision, completion cue,
// device stamp, the Snapshot following the model, and the bar naming the Snapshot's task.
// Run alone with `--only group:D-MACSYS2`. Everything uses scratch stores (in-memory) or the scratch
// directory of the run; the person's store, defaults and Snapshot file are never touched.
// `KRONOS_UITEST_BREAK=1` flips one expectation per group: the run must then fail.
#if !RELEASE
import AppKit
import SwiftData
import KronosCore
import KronosSnapshot

@MainActor
extension LiveUITest {
    static func dMacSys2Steps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard KronosEnv.isHermetic else { record("D-MACSYS2 runs only on a scratch store", false, "not hermetic"); return }
        schemaGuardAtOpen(breakMode: breakMode)
        seedingDecision(breakMode: breakMode)
        completionCue(model, breakMode: breakMode)
        deviceStamp(breakMode: breakMode)
        await snapshotFollowsModel(model, breakMode: breakMode)
        barNamesSnapshotTask(model, breakMode: breakMode)
    }

    // MARK: Schema guard

    private static func schemaGuardAtOpen(breakMode: Bool) {
        guard let fresh = try? TaskStore(inMemory: true), let newer = try? TaskStore(inMemory: true),
              let both = try? TaskStore(inMemory: true) else {
            record("schema guard: scratch stores open", false, "in-memory store failed"); return
        }
        // Hand table: a fresh store is writable and records this build (2); a second open raises nothing.
        let first = StoreOpenGuard.apply(to: fresh, kvs: nil, build: 2)
        let second = StoreOpenGuard.apply(to: fresh, kvs: nil, build: 2)
        record("schema guard: a fresh store is writable, records the build version once",
               first == .writable(raisedStore: true, raisedKVS: false)
                   && second == .writable(raisedStore: false, raisedKVS: false)
                   && fresh.storeMinimumSchemaVersion == (breakMode ? 3 : 2),
               "first=\(first) second=\(second) min=\(String(describing: fresh.storeMinimumSchemaVersion))")
        // A store a newer build wrote (3) is refused by build 2 and left unchanged.
        newer.raiseStoreMinimumSchemaVersion(to: 3)
        let metaBefore = ((try? newer.context.fetch(FetchDescriptor<KStoreMeta>()).count) ?? -1)
        let refused = StoreOpenGuard.apply(to: newer, kvs: nil, build: 2)
        let metaAfter = ((try? newer.context.fetch(FetchDescriptor<KStoreMeta>()).count) ?? -1)
        record("schema guard: an older build is refused on a newer store and writes nothing",
               refused == .readOnly(requires: breakMode ? 2 : 3) && newer.storeMinimumSchemaVersion == 3 && metaBefore == metaAfter,
               "refused=\(refused) min=\(String(describing: newer.storeMinimumSchemaVersion)) rows=\(metaBefore)->\(metaAfter)")
        // The key-value store counts too: the highest minimum of the two wins; a current build raises both.
        let kvs = FixtureSettingsKVS()
        kvs.setSyncedInt(4, forKey: SchemaGuard.kvsKey)
        let viaKVS = StoreOpenGuard.apply(to: both, kvs: kvs, build: 3)
        let raiseKVS = FixtureSettingsKVS()
        let raised = StoreOpenGuard.apply(to: both, kvs: raiseKVS, build: 3)
        record("schema guard: the key-value minimum refuses too, and a current build raises store and key-value store",
               viaKVS == .readOnly(requires: 4) && both.storeMinimumSchemaVersion == 3
                   && raised == .writable(raisedStore: true, raisedKVS: true) && raiseKVS.syncedInt(forKey: SchemaGuard.kvsKey) == 3,
               "viaKVS=\(viaKVS) raised=\(raised) kvs=\(String(describing: raiseKVS.syncedInt(forKey: SchemaGuard.kvsKey)))")
        let text = StoreTooNewError(build: 2, requires: 3).description
        record("schema guard: the readable window text names both versions and is not a raw key",
               text.contains("3") && text.contains("2") && !text.contains("app.schema.toonew") && !text.contains("%"),
               "text=\(text)")
    }

    // MARK: Seeding

    private static func seedingDecision(breakMode: Bool) {
        // (storeIsEmpty, syncEnabled, importDone) -> seed?  Hand-written, not derived from the code.
        let table: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, true), (true, false, true, true),
            (true, true, false, false), (true, true, true, true),
            (false, false, false, false), (false, false, true, false),
            (false, true, false, false), (false, true, true, false),
        ]
        var wrong: [String] = []
        for (empty, sync, done, want) in table {
            let got = LaunchSeeding.shouldSeed(storeIsEmpty: empty, syncEnabled: sync, importDone: done)
            if got != (breakMode && empty && sync && !done ? true : want) { wrong.append("empty=\(empty) sync=\(sync) done=\(done) got=\(got)") }
        }
        record("seeding: only an empty store, and never before a synced store's first import",
               wrong.isEmpty, wrong.isEmpty ? "8 cases ok" : wrong.joined(separator: "; "))
        // This build has sync off: a launch on an empty store may seed, a non-empty one must not.
        record("seeding: this build (sync off) seeds an empty store and leaves a filled one",
               LaunchSeeding.shouldSeed(storeIsEmpty: true) && !LaunchSeeding.shouldSeed(storeIsEmpty: false),
               "syncEnabled=\(KronosStore.isSyncEnabled)")
    }

    // MARK: Completion cue

    private static func completionCue(_ model: AppModel, breakMode: Bool) {
        let store = model.store
        let plain = store.create(title: "dm2 cue plain")
        let parent = store.create(title: "dm2 cue parent")
        _ = store.addSubtaskNoUndo(parent.id, title: "dm2 cue child a")
        _ = store.addSubtaskNoUndo(parent.id, title: "dm2 cue child b")
        var played: [KronosSounds.Cue] = []
        let token = CompletionSound.observe(store: store) { played.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        store.complete(plain.id)
        store.complete(parent.id)
        record("completion cue: a plain task plays the task cue, a parent plays the parent cue (from the real completion notice)",
               played == (breakMode ? [.task, .task] : [.task, .parent]), "played=\(played.map(\.rawValue))")
        record("completion cue: no id and an unknown id fall back to the task cue",
               CompletionSound.cue(forTaskID: nil, store: store) == .task
                   && CompletionSound.cue(forTaskID: UUID(), store: store) == .task, "fallback ok")
    }

    // MARK: Device stamp

    private static func deviceStamp(breakMode: Bool) {
        let current = DeviceOrigin.current
        let stored = KronosEnv.defaults.string(forKey: "kronos.device.id")
        record("device stamp: launch configured this device, id kept in the scratch defaults",
               current != nil && !(current?.id ?? "").isEmpty && stored == (breakMode ? "x" : current?.id),
               "id=\(current?.id ?? "nil") stored=\(stored ?? "nil")")
    }

    // MARK: Snapshot follows the model

    private static func snapshotFollowsModel(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-dm2-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = SnapshotStore(directory: dir)
        let was = model.shownListHead
        let a = store.create(title: "dm2 snap first")
        let b = store.create(title: "dm2 snap second")
        // The list screen publishes its own head too, so the pin (which beats the list head) makes
        // `next` deterministic for the first two checks.
        let wasPin = model.pinnedFocusTaskID
        model.pinnedFocusTaskID = a.id
        model.publishShownListHead(ShownListHead(listName: "Probe", ids: [a.id, b.id]))
        model.didMutate()
        let follower = SnapshotFollower(model: model, directory: dir)
        follower.start()
        defer { follower.stop() }
        let first = await waitUntil(timeout: 5) {
            if case .snapshot(let s) = reader.read() { return s.next?.taskID == a.id }
            return false
        }
        record("snapshot: the writer starts with the app and writes the pinned task as next",
               first, "next=\(snapshotNext(reader))")
        // A model change after the start reaches the file without anyone calling the writer.
        let before = follower.scheduledByModel
        store.update(a.id) { $0.title = "dm2 snap renamed" }
        model.didMutate()
        let renamed = await waitUntil(timeout: 5) {
            if case .snapshot(let s) = reader.read() { return s.next?.title == "dm2 snap renamed" }
            return false
        }
        record("snapshot: didMutate reaches the file through the writer (rename shows in next)",
               renamed && follower.scheduledByModel > before, "next=\(snapshotNext(reader)) scheduled=\(follower.scheduledByModel - before)")
        // Publishing another list head alone (no didMutate) schedules a write, and the file ends equal to
        // what the model resolves now (the list screen may publish again meanwhile, so compare to the model).
        model.pinnedFocusTaskID = nil
        model.didMutate()
        await waitStable { follower.scheduledByModel }
        let beforeHead = follower.scheduledByModel
        model.publishShownListHead(ShownListHead(listName: "Probe two", ids: [b.id, a.id, UUID()]))
        let settled = await waitUntil(timeout: 5) {
            guard case .snapshot(let s) = reader.read() else { return false }
            return s.next?.taskID == SnapshotWriter.snapshot(model: model, now: Date()).next?.taskID
        }
        record("snapshot: publishing another list head schedules a write and the file follows the model",
               settled && follower.scheduledByModel > (breakMode ? follower.scheduledByModel : beforeHead),
               "next=\(snapshotNext(reader)) scheduled=\(follower.scheduledByModel - beforeHead)")
        model.pinnedFocusTaskID = wasPin
        model.publishShownListHead(was)
        model.didMutate()
    }

    private static func snapshotNext(_ reader: SnapshotStore) -> String {
        if case .snapshot(let s) = reader.read() { return s.next?.title ?? "none" }
        return "no file"
    }

    // MARK: Bar and Snapshot agree

    private static func barNamesSnapshotTask(_ model: AppModel, breakMode: Bool) {
        let store = model.store
        let done = store.create(title: "dm2 bar done"); store.complete(done.id)
        let ok = store.create(title: "dm2 bar ok")
        let pinTarget = store.create(title: "dm2 bar pin")
        let was = model.shownListHead
        let wasPin = model.pinnedFocusTaskID
        model.pinnedFocusTaskID = nil
        model.didMutate()
        func bar() -> UUID? { MenuBarOrdoController.focusTaskID(model: model) }
        func popover() -> UUID? { MenuBarFocusResolver.taskID(model: model) }
        func snapshotNext() -> UUID? { SnapshotWriter.snapshot(model: model, now: Date()).next?.taskID }

        model.publishShownListHead(ShownListHead(listName: "Probe", ids: [done.id, ok.id, pinTarget.id]))
        let listHead = (bar(), popover(), snapshotNext())
        model.pinnedFocusTaskID = pinTarget.id
        let pinned = (bar(), popover(), snapshotNext())
        model.pinnedFocusTaskID = nil
        model.publishShownListHead(ShownListHead(listName: "Probe", ids: [done.id]))
        let nothing = (bar(), popover(), snapshotNext())
        model.publishShownListHead(.empty)
        let noList = (bar(), popover(), snapshotNext())
        model.pinnedFocusTaskID = wasPin
        model.publishShownListHead(was)
        model.didMutate()

        record("bar next: the first eligible row (done row skipped), a pin wins, a list with no eligible row means nothing; the bar, the popover and the Snapshot agree",
               listHead.0 == (breakMode ? done.id : ok.id) && listHead.1 == ok.id && listHead.2 == ok.id
                   && pinned.0 == pinTarget.id && pinned.1 == pinTarget.id && pinned.2 == pinTarget.id
                   && nothing.0 == nil && nothing.1 == nil && nothing.2 == nil,
               "list=\(listHead) pin=\(pinned) none=\(nothing)")
        record("bar next: with no list on screen the bar, the popover and the Snapshot use the same Today head",
               noList.0 == noList.1 && noList.1 == noList.2, "noList=\(noList)")
    }
}
#endif
