// Kronos/MenuBar/MenuBarTellOrdo.swift
// "Tell Ordo...": one line typed in the popover reorders the queue shown there. Return
// previews the new order (nothing is written), Return again applies it as ONE undo step.
// Common commands ("Acme first") are parsed locally by `OrdoCommandGrammar`; anything else
// goes to the AI router when one is configured, and a reply that is not an exact permutation
// of the queue is dropped whole.
import SwiftUI
import KronosCore

@MainActor
@Observable
final class TellOrdoState {
    struct Preview: Equatable {
        let ids: [UUID]
        let summary: String
        let changed: Bool
    }
    var text = "" { didSet { if text != oldValue { preview = nil; notice = nil } } }
    var preview: Preview?
    var notice: String?
    var isThinking = false

    /// Builds the preview for `queue` (display order, the focus first). Writes nothing.
    func submit(model: AppModel, queue: [KTask]) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !queue.isEmpty else { return }
        let items = queue.map { OrdoQueueItem(title: $0.title, project: $0.project?.name) }
        if let result = OrdoCommandGrammar.parse(message, queue: items) {
            let summary = String(format: String(localized: result.toFront ? "menubar.tell.moved.front" : "menubar.tell.moved.back"), result.matched)
            show(order: result.order, queue: queue, summary: summary)
            return
        }
        guard let ai = model.ai else { notice = String(localized: "menubar.tell.unknown"); return }
        isThinking = true
        defer { isThinking = false }
        let language = KronosLocale.current.language.languageCode?.identifier == "hr" ? "hr" : "en"
        let reply = try? await ai.ordoResort(queueTitles: queue.map(\.title), message: message, history: [], language: language)
        guard let reply, !reply.isNoOp, OrdoCommandGrammar.isPermutation(reply.order, count: queue.count) else {
            notice = String(localized: "menubar.tell.unknown"); return
        }
        show(order: reply.order, queue: queue, summary: reply.explanation)
    }

    private func show(order: [Int], queue: [KTask], summary: String) {
        let changed = !OrdoCommandGrammar.isIdentity(order)
        preview = Preview(ids: order.map { queue[$0 - 1].id }, summary: changed ? summary : String(localized: "menubar.tell.nochange"),
                          changed: changed)
    }

    /// Applies the previewed order: the queue's tasks take each other's sort slots in the new order
    /// (one grouped undo step) and the new first task becomes the pin. The pill's Undo restores the
    /// store step and the previous pin together.
    func apply(model: AppModel) {
        guard let preview, preview.changed else { return }
        let store = model.store
        let tasks = preview.ids.compactMap { store.task($0) }
        guard tasks.count == preview.ids.count else { return }
        var slots = tasks.map(\.sortIndex).sorted()
        if Set(slots).count != slots.count { slots = slots.indices.map { (slots.first ?? 0) + Double($0) } }
        let previousPin = model.pinnedFocusTaskID
        store.groupedUndo("Reorder") {
            for (task, slot) in zip(tasks, slots) where task.sortIndex != slot {
                store.update(task.id) { $0.sortIndex = slot }
            }
        }
        model.pinnedFocusTaskID = tasks.first?.id
        model.didMutate()
        UndoToastCenter.shared.show(String(localized: "menubar.tell.applied"), customUndo: { [weak model] in
            guard let model else { return }
            model.store.undo()
            model.pinnedFocusTaskID = previousPin
            model.didMutate()
        })
        text = ""
    }
}

struct MenuBarTellOrdo: View {
    let model: AppModel
    /// The queue the popover shows: the focus task first, then the Next rows.
    let queue: [KTask]
    @State private var state = TellOrdoState()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            KTextField(String(localized: "menubar.tell.placeholder"), text: $state.text, leading: "list-ordered")
                .onSubmit { submit() }
                .uiTestAnchor("menubar.tell.field")
            if state.isThinking {
                Text(String(localized: "menubar.tell.thinking")).font(Typo.meta).foregroundStyle(Tok.textSecondary)
            } else if let notice = state.notice {
                Text(notice).font(Typo.meta).foregroundStyle(Tok.textSecondary)
            }
            if let preview = state.preview { previewView(preview) }
        }
    }

    private func submit() {
        if let preview = state.preview {
            if preview.changed { state.apply(model: model) } else { state.text = "" }
        } else {
            Task { await state.submit(model: model, queue: queue) }
        }
    }

    private func previewView(_ preview: TellOrdoState.Preview) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: "menubar.tell.preview"))
                .font(Typo.caption).tracking(Tracking.caption).textCase(.uppercase)
                .foregroundStyle(Tok.textTertiary)
            ForEach(Array(preview.ids.enumerated()), id: \.offset) { index, id in
                HStack(spacing: Space.x2) {
                    Text("\(index + 1)").font(Typo.count).foregroundStyle(Tok.textTertiary)
                        .frame(minWidth: Metrics.iconM, alignment: .trailing)
                    Text(model.store.task(id)?.title ?? "").font(Typo.row).foregroundStyle(Tok.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            Text(preview.summary).font(Typo.meta).foregroundStyle(Tok.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.x2) {
                Spacer(minLength: 0)
                Button(String(localized: "common.cancel")) { state.text = "" }
                    .kButton(.ghost, size: .compact)
                if preview.changed {
                    Button(String(localized: "menubar.tell.apply")) { state.apply(model: model) }
                        .kButton(.secondary, size: .compact)
                        .uiTestAnchor("menubar.tell.apply")
                }
            }
        }
        .padding(Space.x3)
        .background(Tok.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
