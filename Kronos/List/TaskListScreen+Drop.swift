// Kronos/List/TaskListScreen+Drop.swift
// Wires the list's drag-and-drop engine (DropZoneController, DropOverlayView, DropZoneIndicators)
// into TaskListScreen: the drop layer modifier and the order/sort snapshot the engine decides on.
import SwiftUI
import KronosCore

/// Owns the engine for one list: coordinate space for the row frames, the AppKit overlay and the
/// indicators drawn above it.
struct ListDropLayer: ViewModifier {
    let model: AppModel
    let config: ListDropConfig
    @State private var controller: ListDropController

    init(model: AppModel, config: ListDropConfig) {
        self.model = model
        self.config = config
        _controller = State(initialValue: ListDropController(model: model))
    }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: DropSpace.name)
            .onPreferenceChange(DropRowFramesKey.self) { frames in
                MainActor.assumeIsolated { controller.setRowFrames(frames) }
            }
            .overlay { ListDropOverlay(controller: controller, config: config) }
            .overlay { ListDropIndicators(controller: controller) }
    }
}

extension View {
    func listDropLayer(model: AppModel, config: ListDropConfig) -> some View {
        modifier(ListDropLayer(model: model, config: config))
    }
}

extension TaskListScreen {
    /// What the engine needs to know about this list right now: display order, each task's step
    /// order, whether level-0 order is the user's own (manual sort), and the scope new tasks land in.
    func dropConfig(_ ctx: ListContext) -> ListDropConfig {
        let manual = ctx.options.sort == [.asc(.manual)]
        let display = ctx.rows.map(\.id)
        let manualOrder = manual ? display : KTaskSorter.sorted(ctx.rows, by: [.asc(.manual)]).map(\.id)
        var steps: [UUID: [UUID]] = [:]
        for task in ctx.rows {
            let ordered = task.orderedChildren
            if !ordered.isEmpty { steps[task.id] = ordered.map(\.id) }
        }
        return ListDropConfig(order: DropOrder(tasks: display, subtasks: steps), manualOrder: manualOrder,
                              isManualSort: manual, scope: model.scope)
    }
}
