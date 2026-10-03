// Kronos/App/AppModel+Startup.swift
// Launch wiring that reads or follows the shared AppModel: the schema guard at store open, the
// seeding decision, the completion cue and the Snapshot writer that follows every mutation.
// Pure decisions live in small enums so a live step can run them against a scratch store.
import AppKit
import Observation
import KronosCore
import KronosSnapshot

// MARK: - Schema guard at store open

/// A store written by a newer build must not be written by this one. The minimum lives in two
/// places (the store's own `KStoreMeta` row and, with sync on, the iCloud key-value store);
/// the highest wins.
@MainActor
enum StoreOpenGuard {
    enum Decision: Equatable {
        /// This build may write. The flags say whether the recorded minimum was raised in the store / key-value store.
        case writable(raisedStore: Bool, raisedKVS: Bool)
        /// An older build than the data: show the readable window, write nothing.
        case readOnly(requires: Int)
    }

    /// Reads the recorded minimums, then either raises them to `build` (this build is current) or
    /// refuses. `kvs` is nil while sync is off: the store row is then the only record.
    static func apply(to store: TaskStore, kvs: (any SettingsKVS)?, build: Int = SchemaGuard.currentBuildVersion) -> Decision {
        let kvsMinimum = kvs.flatMap { SchemaGuard.minimum(in: $0) }
        switch SchemaGuard.mode(build: build, minimums: [kvsMinimum, store.storeMinimumSchemaVersion]) {
        case .readOnly(let requires):
            return .readOnly(requires: requires)
        case .readWrite:
            let raisedStore = store.raiseStoreMinimumSchemaVersion(to: build)
            let raisedKVS = kvs.map { SchemaGuard.raiseMinimum(to: build, in: $0) } ?? false
            return .writable(raisedStore: raisedStore, raisedKVS: raisedKVS)
        }
    }

    /// The key-value store of this launch: iCloud's only when sync is on (this build has no iCloud entitlement).
    static func liveKVS(syncEnabled: Bool = KronosStore.isSyncEnabled) -> (any SettingsKVS)? {
        syncEnabled ? NSUbiquitousKeyValueStore.default : nil
    }
}

/// Shown by the readable launch window when the store is newer than this build.
struct StoreTooNewError: Error, CustomStringConvertible {
    let build: Int
    let requires: Int

    var description: String {
        String(format: String(localized: "app.schema.toonew"), build, requires)
    }
}

// MARK: - Seeding

/// First launch seeding: only an empty store, and never before a synced store's first import.
enum LaunchSeeding {
    /// `importDone` has no source while sync is off (the policy ignores it then). With sync on and
    /// no import signal yet the answer stays "do not seed": a late first import must never double the data.
    static func shouldSeed(storeIsEmpty: Bool, syncEnabled: Bool = KronosStore.isSyncEnabled, importDone: Bool = false) -> Bool {
        storeIsEmpty && SeedPolicy.shouldSeed(syncEnabled: syncEnabled, importDone: importDone)
    }
}

// MARK: - Completion cue

enum CompletionSound {
    /// The cue for a finished task: the parent cue for a task that had children, else the task cue.
    /// A notification without an id falls back to the task cue.
    @MainActor
    static func cue(forTaskID id: UUID?, store: TaskStore?) -> KronosSounds.Cue {
        guard let id, let store else { return .task }
        return ListCompletion.cue(forCompleted: id, store: store)
    }

    /// Plays the cue of every task a person completes (Core announces nothing for machine writes).
    /// `play` is replaceable so a live step can record the cue instead of making a sound.
    @MainActor
    static func observe(store: TaskStore,
                        play: @escaping @MainActor (KronosSounds.Cue) -> Void = { KronosSounds.play($0) }) -> NSObjectProtocol {
        nonisolated(unsafe) let play = play   // only ever called on the main actor, inside assumeIsolated
        return NotificationCenter.default.addObserver(forName: .kronosTaskDidComplete, object: nil, queue: .main) { [weak store] note in
            MainActor.assumeIsolated {
                play(cue(forTaskID: note.userInfo?["taskID"] as? UUID, store: store))
            }
        }
    }
}

// MARK: - Snapshot writer follows the model

/// Creates the one Snapshot writer and re-schedules it whenever the model's mutation counter or
/// its published list head changes. `AppModel.didMutate` bumps `version` and
/// `publishShownListHead` assigns `shownListHead`, so following those two properties is the same
/// as calling `writer.schedule()` from both methods, without a second code path in the model.
@MainActor
final class SnapshotFollower {
    private let model: AppModel
    let writer: SnapshotWriter
    private var running = false
    /// Counts schedule calls driven by a model change (the live step reads it).
    private(set) var scheduledByModel = 0

    init(model: AppModel, directory: URL? = nil, onChange: @escaping () -> Void = {}) {
        self.model = model
        if let directory {
            writer = SnapshotWriter(model: model, directory: directory, onChange: onChange)
        } else {
            writer = SnapshotWriter(model: model, onChange: onChange)
        }
    }

    func start() {
        guard !running else { return }
        running = true
        writer.start()
        follow()
    }

    func stop() { running = false }

    private func follow() {
        guard running else { return }
        withObservationTracking {
            _ = model.version
            _ = model.shownListHead
        } onChange: { [weak self] in
            // onChange runs before the new value lands; hop so the writer reads the settled model.
            Task { @MainActor in
                guard let self, self.running else { return }
                self.scheduledByModel += 1
                self.writer.schedule()
                self.follow()
            }
        }
    }
}
