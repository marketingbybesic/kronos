// Kronos/Detail/InspectorFieldContextMenu.swift — right click on an inspector field.
//
// Each field gets "Clear" plus its quick values and nothing the field's own picker already
// does (no date grid, no free typing). Every change is ONE undo step and choosing the value
// the field already has changes nothing and pushes nothing.
import SwiftUI
import KronosCore

enum InspectorField: String {
    case due, priority, effort, status, estimate, depth
}

@MainActor
enum InspectorFieldMenu {
    static let estimateQuickMinutes = [5, 15, 30, 60, 120]
    /// Statuses a person picks by hand (Done is the checkbox, Canceled is delete).
    static let quickStatuses: [KStatus] = [.todo, .inProgress, .waiting, .someday]

    static func nodes(_ field: InspectorField, task: KTask, model: AppModel) -> [CtxNode] {
        let store = model.store
        let id = task.id

        /// Run `change` only when the field really differs from `isCurrent`.
        func apply(_ isCurrent: Bool, _ change: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            { guard !isCurrent else { return }; change(); model.didMutate() }
        }

        switch field {
        case .due:
            let today = Day.today()
            func day(_ nodeID: String, _ title: String, _ value: Int) -> CtxNode {
                .action(nodeID, title, checked: task.dueDay == value,
                        apply(task.dueDay == value) { store.setDue(id, day: value) })
            }
            return [
                day("today", String(localized: "deadline.quick.today"), today),
                day("tomorrow", String(localized: "deadline.quick.tomorrow"), today + 1),
                day("nextweek", String(localized: "deadline.quick.nextweek"), today + 7),
                .divider("div"),
                .action("clear", String(localized: "ctx.field.clear"), enabled: task.dueDay != nil,
                        apply(task.dueDay == nil) { store.setDue(id, day: nil) }),
            ]

        case .priority:
            let values = KPriority.allCases.filter { $0 != .none }.reversed()
            return values.map { (p: KPriority) -> CtxNode in
                .action("\(p.rawValue)", p.displayName, checked: task.priority == p,
                        apply(task.priority == p) { store.setPriority(id, p) })
            } + [
                .divider("div"),
                .action("clear", String(localized: "ctx.field.clear"), enabled: task.priority != .none,
                        apply(task.priority == .none) { store.setPriority(id, .none) }),
            ]

        case .effort:
            return KEffort.allCases.filter { $0 != .none }.map { (e: KEffort) -> CtxNode in
                .action("\(e.rawValue)", e.displayName, checked: task.effort == e,
                        apply(task.effort == e) { store.setEffort(id, e) })
            } + [
                .divider("div"),
                .action("clear", String(localized: "ctx.field.clear"), enabled: task.effort != .none,
                        apply(task.effort == .none) { store.setEffort(id, .none) }),
            ]

        case .estimate:
            return estimateQuickMinutes.map { (m: Int) -> CtxNode in
                .action("\(m)", String(format: String(localized: "ctx.field.estimate.min"), m),
                        checked: task.estimateMinutes == m,
                        apply(task.estimateMinutes == m) { store.setEstimate(id, minutes: m) })
            } + [
                .divider("div"),
                .action("clear", String(localized: "ctx.field.clear"), enabled: task.estimateMinutes != nil,
                        apply(task.estimateMinutes == nil) { store.setEstimate(id, minutes: nil) }),
            ]

        case .depth:
            return [KDepth.shallow, KDepth.deep].map { (d: KDepth) -> CtxNode in
                .action("\(d.rawValue)", d.displayName, checked: task.depth == d,
                        apply(task.depth == d) { store.setDepth(id, d) })
            } + [
                .divider("div"),
                .action("clear", String(localized: "ctx.field.clear"), enabled: task.depth != .unknown,
                        apply(task.depth == .unknown) { store.setDepth(id, .unknown) }),
            ]

        case .status:
            // A status cannot be empty, so no Clear: the quick values are the whole menu.
            return quickStatuses.map { (s: KStatus) -> CtxNode in
                .action("\(s.rawValue)", s.displayName, checked: task.status == s,
                        apply(task.status == s) { store.setStatus(id, s) })
            }
        }
    }
}

private struct InspectorFieldMenuModifier: ViewModifier {
    let field: InspectorField
    let task: KTask
    let model: AppModel

    func body(content: Content) -> some View {
        content.kContextMenu(id: "field.\(field.rawValue).\(task.id.uuidString)") {
            InspectorFieldMenu.nodes(field, task: task, model: model)
        }
    }
}

extension View {
    /// The Clear + quick-values menu of an inspector field.
    func kInspectorFieldMenu(_ field: InspectorField, task: KTask, model: AppModel) -> some View {
        modifier(InspectorFieldMenuModifier(field: field, task: task, model: model))
    }
}
