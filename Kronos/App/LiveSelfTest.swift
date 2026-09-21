// Live self-test: `KRONOS_SELFTEST=<report.json>` + `KRONOS_STORE_DIR=<scratch dir>` makes the REAL
// app run one scripted scenario against a scratch store, write a JSON report and quit. It proves
// the wiring no snapshot can (auto-triage on creation, completion + undo, presets, the hotkey
// conflict check against THIS Mac) without anyone clicking. Refuses to run on the real store.
import AppKit
import CoreSpotlight
import KronosCore

// Release stub: `reportPath` is read unconditionally by `AIWiring.configure(_:)`
// (Kronos/App/AIWiring.swift:21, a file this leaf does not own) to pick the on-device-only AI
// path during a self-test. Hardcoding `nil` here means that branch is simply never taken in
// Release (there is no env var that could make it true), and the real implementation — which
// drives the app through a scripted scenario and writes a report — never links in.
#if RELEASE
@MainActor
enum LiveSelfTest {
    static var reportPath: String? { nil }
    static func run(model: AppModel, autoTriage: AutoTriage?) {}
}
#else
@MainActor
enum LiveSelfTest {
    static var reportPath: String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["KRONOS_SELFTEST"], !path.isEmpty,
              let dir = env["KRONOS_STORE_DIR"], !dir.isEmpty else { return nil }
        return path
    }

    static func run(model: AppModel, autoTriage: AutoTriage?) {
        guard let path = reportPath else { return }
        // The first scratch launch indexed seed tasks into the real Spotlight index: ask for them to be
        // removed. Fire and forget - awaiting the async variant never returned in an ad-hoc build.
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
        Task { @MainActor in
            var report: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: Date())]
            // The first scratch launch indexed seed tasks into the real Spotlight index: remove them.

            let store = model.store
            report["seedTasks"] = store.allTasks().count
            report["projectsWithIcon"] = store.allProjects(includeArchived: false).filter { $0.icon != nil }.count
            report["aiConfigured"] = model.ai != nil
            report["appleIntelligence"] = AppleIntelligence.availability.statusLine

            // 1. Creation triggers auto-triage (fill-only). Wait for the fill, up to 25 s.
            let task = store.create(title: "Send the September invoice to Acme")
            model.didMutate()
            var waited = 0.0
            while autoTriage?.lastFill[task.id] == nil && waited < 25 {
                try? await Task.sleep(for: .milliseconds(500)); waited += 0.5
            }
            let fill = autoTriage?.lastFill[task.id]
            report["triageWaitedSeconds"] = waited
            report["triageFilled"] = fill?.fields.map(\.rawValue) ?? []
            report["triageReason"] = fill?.reason ?? ""
            report["firstMoveAfterTriage"] = store.task(task.id)?.firstMove ?? ""

            // 2. Completion announces once (the sound path) and undo reopens the task.
            let counter = CompletionCounter()
            let token = NotificationCenter.default.addObserver(forName: .kronosTaskDidComplete, object: nil,
                                                               queue: .main) { _ in
                MainActor.assumeIsolated { counter.count += 1 }
            }
            store.complete(task.id)
            let doneAfterComplete = store.task(task.id)?.status == .done
            store.undo()
            let openAfterUndo = store.task(task.id)?.status != .done
            NotificationCenter.default.removeObserver(token)
            report["completionAnnounced"] = counter.count
            report["doneAfterComplete"] = doneAfterComplete
            report["openAfterUndo"] = openAfterUndo

            // 3. An Ordo preset rewrites the open list's sort.
            let before = model.options(for: .all).sort
            model.coach.applyPreset("quickwins", to: .all)
            report["presetChangedSort"] = model.options(for: .all).sort != before
            report["activePreset"] = model.coach.activePreset(for: .all).id

            // 4. The three global hotkeys against THIS Mac's system shortcuts and installed apps.
            let system = SymbolicHotkeyReader.enabledDefaults()
            let installed = HotkeyConflictChecker.installedBundleIDs()
            var clashes: [String: String] = [:]
            for entry in HotkeyRegistry.entries where entry.scope == .global {
                let binding = HotkeyRegistry.current(for: entry.id) ?? entry.defaultBinding
                if let c = HotkeyConflictChecker.globalConflict(binding, systemDefaults: system,
                                                                installedBundleIDs: installed) {
                    clashes[entry.id] = c.describesClash
                }
            }
            report["globalHotkeyClashes"] = clashes
            report["installedClashApps"] = installed.sorted()
            report["calendarAccess"] = String(describing: model.coach.calendarAccess)
            report["finishedAt"] = ISO8601DateFormatter().string(from: Date())

            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class CompletionCounter { var count = 0 }
#endif
