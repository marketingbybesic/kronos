// SnapshotWriter: the one producer of Snapshot.json on this device (KronosSnapshot package).
// `next` is resolved with the SAME precedence the menu bar uses (current time block, then the
// pin, then the first eligible row of `model.shownListHead`, falling back to
// `NextFallback.todayHead` when no list is on screen), and `today[0..<8]` is that head's
// eligible rows in order, so a reader never disagrees with the bar.
// Writes are debounced 300 ms and skipped when nothing a reader renders changed.
import Foundation
import KronosCore
import KronosSnapshot

@MainActor
final class SnapshotWriter {
    private let model: AppModel
    private let store: SnapshotStore
    private let onChange: () -> Void
    private var pending: Task<Void, Never>?
    private var tokens: [NSObjectProtocol] = []

    /// - Parameter onChange: called only after a write that changed rendered content (widget
    ///   reload hook; empty until the extensions exist).
    init(model: AppModel, directory: URL = KronosStore.containerDirectory().appendingPathComponent("Snapshot", isDirectory: true),
         onChange: @escaping () -> Void = {}) {
        self.model = model
        self.store = SnapshotStore(directory: directory)
        self.onChange = onChange
    }

    /// Listens for the events that can change `next` or `today` and writes once now.
    /// A snapshot-image run (`KRONOS_SNAPSHOT`) never writes.
    func start() {
        guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.kronosOrdoFocusDidChange, .kronosDayDidChange, CoachSettingsStore.didChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedule() }
            })
        }
        schedule()
    }

    /// Call after any store mutation that may change the shown list (AppModel.didMutate).
    func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    func writeNow(now: Date = Date()) {
        guard let result = try? store.write(Self.snapshot(model: model, now: now)), result == .written else { return }
        onChange()
    }

    static func snapshot(model: AppModel, now: Date) -> Snapshot {
        let lookup = model.store.allTasks()
        let published = model.shownListHead
        // No list on screen yet (cold launch, menu bar only): the same Today fallback MCP uses.
        let headIDs = published.ids.isEmpty
            ? NextFallback.todayHead(store: model.store, today: Day.today(), limit: ShownListHead.maxIDs)
            : published.ids
        let rows = headIDs.compactMap { id in lookup.first { $0.id == id } }
        let label: String? = published.ids.isEmpty || model.scope == .today ? nil : published.listName
        let pin = model.pinnedFocusTaskID
        let picked = NextEligibility.pick(pinned: pin, rows: rows, lookup: lookup)
        let head = SnapshotHead.resolve(blockFocus: TimeBlocksModel(model: model).blockFocusTaskID,
                                        pin: picked.flatMap { $0.id == pin ? pin : nil },
                                        shownHead: picked?.id)
        let next = head.flatMap { h in
            lookup.first { $0.id == h.taskID }.map { item($0, label: label, pinned: h.pinned) }
        }
        let shown = rows.filter { NextEligibility.isEligible($0, lookup: lookup) }.map { item($0, label: label, pinned: false) }
        let picker = model.store.allTasks()
            .filter { KStatus.open.contains($0.status) && $0.parent == nil }
            .map { SnapshotPickerRow(id: $0.id, title: $0.title, projectName: $0.project?.name ?? "") }
        let input = SnapshotInput(next: next, shown: shown, picker: picker,
                                  accentHex: model.coach.settings.accentHex ?? "",
                                  chroma: model.chromaMode == .full ? 1 : 0)
        return SnapshotBuilder.build(input, now: now)
    }

    private static func item(_ t: KTask, label: String?, pinned: Bool) -> SnapshotItem {
        SnapshotItem(taskID: t.id, title: t.title, firstMove: FirstMoveLogic.moveText(for: t),
                     projectHex: t.project?.colorHex, listLabel: label, pinned: pinned)
    }
}
