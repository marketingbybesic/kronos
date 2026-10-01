// Kronos/Detail/InspectorWaitsOnRow.swift
// "Waits on": the tasks this one cannot start before. Same borderless KPropertyRow shape as
// Labels: chips for what it waits on (tap removes), a "+" that opens a small searchable picker.
// The picker lists open tasks only, never the task itself, never one already chosen, and never
// one that would close a loop (TaskStore.wouldCreateCycle). Blocked is derived in Core, so this
// row only edits the list; the "Blocked" chip lives beside Waiting in InspectorStatusSection.
import SwiftUI
import KronosCore

struct InspectorWaitsOnRow: View {
    let model: AppModel
    let task: KTask
    @State private var isAdding = false
    @State private var query = ""
    @State private var isAddHovering = false

    var body: some View {
        let _ = model.version
        KPropertyRow(String(localized: "detail.waitson.label")) {
            // Chips and the "+" share one flow, so the "+" sits right after the last chip and wraps
            // with them instead of drifting to the row's far edge.
            InspectorFlowLayout(spacing: Space.x1) {
                ForEach(chosen, id: \.id) { other in
                    KChip(other.title, trailing: .clear, onTap: { remove(other.id) })
                        .frame(maxWidth: 180, alignment: .leading)
                }
                // Frame + contentShape INSIDE the label (a plain-style button is pressable only on
                // its opaque pixels), ink aligned to the shared value x like the Labels "+".
                Button { isAdding = true } label: {
                    Icon("plus", size: Metrics.iconS)
                        .foregroundStyle(isAddHovering ? Tok.textPrimary : Tok.textTertiary)
                        .frame(width: Metrics.minHit, height: Metrics.minHit, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isAddHovering = $0 }
                .animation(Motion.hover, value: isAddHovering)
                .accessibilityLabel(String(localized: "detail.waitson.add"))
                .popover(isPresented: $isAdding) { pickerContent }
            }
        }
    }

    // MARK: Data

    /// What this task waits on, resolved to live tasks. A deleted blocker simply drops out of
    /// the display; the stored id is cleaned the next time the list is edited.
    private var chosen: [KTask] {
        task.waitsOn.compactMap { model.store.task($0) }
    }

    /// Candidates: open, not itself, not chosen, no cycle, matching the search. Capped so a
    /// 2,000-task store never builds 2,000 rows.
    private var candidates: [KTask] {
        let have = Set(task.waitsOn)
        let needle = KTextFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return model.store.allTasks()
            .filter { $0.id != task.id && KStatus.open.contains($0.status) && !have.contains($0.id) }
            .filter { needle.isEmpty || KTextFold.fold($0.title).contains(needle) }
            .filter { !model.store.wouldCreateCycle(task.id, waitingOn: $0.id) }
            .sorted { KTextFold.fold($0.title) < KTextFold.fold($1.title) }
            .prefix(8).map { $0 }
    }

    // MARK: Picker

    /// Internal so the snapshot harness can render the popover content on its own (a presented
    /// popover cannot be captured).
    var pickerContent: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            KTextField(String(localized: "detail.waitson.search"), text: $query, autofocus: true)
            let list = candidates
            if list.isEmpty {
                Text(String(localized: "detail.waitson.empty"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .frame(height: Metrics.minHit, alignment: .leading)
            } else {
                ForEach(list, id: \.id) { other in
                    Button { add(other.id) } label: {
                        Text(other.title)
                            .font(Typo.row)
                            .foregroundStyle(Tok.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: Metrics.minHit + Space.x1, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Space.x3)
        .frame(width: 280)
        .background(Tok.overlay)
    }

    // MARK: Edits

    private func add(_ id: UUID) {
        model.store.setWaitsOn(task.id, task.waitsOn + [id])
        model.didMutate()
        query = ""
        isAdding = false
    }

    private func remove(_ id: UUID) {
        model.store.setWaitsOn(task.id, task.waitsOn.filter { $0 != id })
        model.didMutate()
    }
}
