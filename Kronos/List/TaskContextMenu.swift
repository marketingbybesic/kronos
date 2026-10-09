// Kronos/List/TaskContextMenu.swift — the context menu of a task row, top-level or child.
//
// ONE builder serves both. Which entries exist comes from `TaskMenuSpec` (KronosCore, tested
// with hand-written lists and a shape test): a child gets everything a task has except the
// entries that break a task down into subtasks or move it to another project, plus "Make
// standalone task" and "Move under…". Entries that would offer nothing are not built (no labels
// exist, no task to move under); items that do nothing right now are hidden by the renderer.
// Submenus hold plain choices only (one level). Every store action is ONE undo step and raises
// the undo pill (`model.commit`); an item that would change nothing pushes nothing and says
// nothing. Labels and the date choices are the same everywhere: Today · Tomorrow · Next week ·
// Pick… · Clear; Complete; Pin as focus.
import SwiftUI
import AppKit
import KronosCore

@MainActor
enum TaskMenu {
    /// Most tasks listed under "Move under…"; a menu of hundreds is not a menu.
    static let moveTargetLimit = 20

    /// Open top-level tasks in the same project as `parent` (or all unfiled ones), excluding
    /// the parent itself, in manual order.
    static func moveTargets(parent: KTask, model: AppModel) -> [KTask] {
        model.store.allTasks()
            .filter { $0.id != parent.id && $0.projectID == parent.projectID && KStatus.open.contains($0.status) }
            .sorted { $0.sortIndex < $1.sortIndex }
            .prefix(moveTargetLimit)
            .map { $0 }
    }

    /// `pickDue` opens the date field of the view the menu is attached to; `onSelect` selects
    /// the task (the row's own selection handler).
    static func nodes(task: KTask, model: AppModel,
                      pickDue: @escaping @MainActor () -> Void,
                      onSelect: @escaping @MainActor () -> Void) -> [CtxNode] {
        let isChild = task.isSubtask
        let targets = task.parent.map { moveTargets(parent: $0, model: model) } ?? []
        let availability = TaskMenuAvailability(hasLabels: !model.store.labels().isEmpty, hasMoveTargets: !targets.isEmpty)
        var nodes = TaskMenuSpec.items(isChild: isChild, withLink: true, availability: availability).map { item in
            node(for: item, task: task, model: model, targets: targets, pickDue: pickDue, onSelect: onSelect)
        }
        // A template is a whole task with its steps, so only top-level rows offer it. It sits
        // right before the divider that precedes Delete (after Copy / Copy link).
        if !isChild {
            let at = nodes.lastIndex { $0.id == TaskMenuItem.divider3.rawValue } ?? nodes.endIndex
            nodes.insert(.action(saveTemplateNodeID, String(localized: "ctx.task.savetemplate"),
                                 help: String(localized: "ctx.task.savetemplate.help")) {
                TemplateActions.save(taskID: task.id, model: model)
            }, at: at)
        }
        // The person's "reviewed" phase-gate mark (finish-round-1 B3): works on any task,
        // child or top-level, same as the inspector's markReviewedControl. Backed by the
        // device-local activity log (ReviewedMarkHub, Detail/InspectorScreen.swift), NOT a
        // KTask field. Right before the divider that precedes Delete.
        let reviewedAt3 = nodes.lastIndex { $0.id == TaskMenuItem.divider3.rawValue } ?? nodes.endIndex
        let isReviewed = ReviewedMarkHub.shared?.isReviewed(task.id) ?? false
        nodes.insert(.action(markReviewedNodeID, String(localized: isReviewed ? "ctx.task.unreviewed" : "ctx.task.reviewed"),
                             checked: isReviewed,
                             help: String(localized: isReviewed ? "detail.help.reviewed.unmark" : "detail.help.reviewed.mark")) {
            ReviewedMarkHub.shared?.setReviewed(!isReviewed, taskID: task.id, agentID: task.agentID)
            model.didMutate()
            UndoToastCenter.shared.showNotice(String(format: String(localized: isReviewed ? "undo.unreviewed.name" : "undo.reviewed.name"), task.title))
        }, at: reviewedAt3)
        return nodes
    }

    /// Node id of "Save as Template".
    static let saveTemplateNodeID = "savetemplate"
    /// Node id of "Mark reviewed" / "Unmark reviewed".
    static let markReviewedNodeID = "reviewed"

    /// Node id of the "Avoiding it" toggle.
    static let dreadNodeID = TaskMenuItem.dread.rawValue

    private static func node(for item: TaskMenuItem, task: KTask, model: AppModel, targets: [KTask],
                             pickDue: @escaping @MainActor () -> Void,
                             onSelect: @escaping @MainActor () -> Void) -> CtxNode {
        let store = model.store
        let id = task.id
        let key = item.rawValue
        switch item {
        case .divider1, .divider2, .divider3:
            return .divider(key)

        case .complete:
            return .action(key, task.status == .done ? String(localized: "ctx.task.undone") : String(localized: "bar.menu.complete")) {
                ListCompletion.toggle(task, store: store, model: model)
            }

        case .focus:
            let pinned = id == model.pinnedFocusTaskID
            return .action(key, pinned ? String(localized: "ctx.task.unpinfocus") : String(localized: "hotkey.list.focuspin"),
                           help: String(localized: "ctx.task.focus.help")) {
                ListFocusPin.toggle(id, title: task.title, model: model)
            }

        case .dread:
            return .action(key, String(localized: "ctx.task.dread"), checked: task.dread,
                           help: String(localized: "ctx.task.dread.help")) {
                let now = store.task(id)?.dread ?? task.dread
                store.setDread(id, !now)
                let format = now ? String(localized: "list.pill.notavoiding") : String(localized: "list.pill.avoiding")
                model.commit(String(format: format, task.title))
            }

        case .breakdown:
            return .action(key, String(localized: "ctx.task.breakdown"), help: String(localized: "ctx.task.breakdown.help")) {
                onSelect()
                ListBreakdown.request(id, model: model)
            }

        case .details:
            return .action(key, String(localized: "ctx.subtask.details")) {
                model.openDetails(taskID: id)
            }

        case .due:
            return .submenu(key, String(localized: "ctx.task.due"), dueNodes(task: task, model: model, pickDue: pickDue))

        case .priority:
            return .submenu(key, String(localized: "ctx.task.priority"), KPriority.allCases.map { (p: KPriority) -> CtxNode in
                .action("priority.\(p.rawValue)", ViewOptionsMapper.priorityName(p), checked: task.priorityRaw == p.rawValue) {
                    guard task.priorityRaw != p.rawValue else { return }
                    store.setPriority(id, p)
                    model.commit(String(format: String(localized: "undo.priority.name"), ViewOptionsMapper.priorityName(p), task.title))
                }
            })

        case .status:
            return .submenu(key, String(localized: "ctx.task.status"),
                            [KStatus.todo, .inProgress, .waiting, .someday].map { (st: KStatus) -> CtxNode in
                .action("status.\(st.rawValue)", ViewOptionsMapper.statusName(st), checked: task.status == st,
                        help: statusHelp(st)) {
                    guard task.status != st else { return }
                    // Waiting goes through its own writer: it also plans the check-in day.
                    if st == .waiting { store.setWaiting(id, true) } else { store.setStatus(id, st) }
                    model.commit(String(format: String(localized: "list.pill.status"), ViewOptionsMapper.statusName(st), task.title))
                }
            })

        case .effort:
            return .submenu(key, String(localized: "ctx.task.effort"), KEffort.allCases.map { (e: KEffort) -> CtxNode in
                .action("effort.\(e.rawValue)", ViewOptionsMapper.effortName(e), checked: task.effortRaw == e.rawValue) {
                    guard task.effortRaw != e.rawValue else { return }
                    store.setEffort(id, e)
                    model.commit(String(format: String(localized: "list.pill.effort"), ViewOptionsMapper.effortName(e), task.title))
                }
            })

        case .labels:
            return .submenu(key, String(localized: "ctx.task.label"), LabelMenu.taskToggleNodes(task: task, model: model))

        case .move:
            var kids: [CtxNode] = [
                .action("move.none",
                        String(localized: "detail.noproject"), checked: task.projectID == nil) {
                    guard task.projectID != nil else { return }
                    store.move(id, toProject: nil)
                    model.commit(String(format: String(localized: "undo.moved.name"), String(localized: "detail.noproject")))
                },
            ]
            kids += store.allProjects().map { (p: KProject) -> CtxNode in
                .action("move.\(p.id.uuidString)", p.name, checked: task.projectID == p.id) {
                    guard task.projectID != p.id else { return }
                    store.move(id, toProject: p)
                    model.commit(String(format: String(localized: "undo.moved.name"), p.name))
                }
            }
            return .submenu(key, String(localized: "ctx.task.move"), kids)

        case .standalone:
            return .action(key, String(localized: "ctx.subtask.promote")) {
                store.promoteSubtaskToTask(id)
                model.commit(String(format: String(localized: "undo.promoted.name"), task.title))
            }

        case .moveUnder:
            return .submenu(key, String(localized: "ctx.subtask.reparent"), targets.map { (t: KTask) -> CtxNode in
                .action("moveunder.\(t.id.uuidString)", t.title) {
                    store.reparentSubtask(id, under: t.id)
                    model.commit(String(format: String(localized: "undo.movedunder.name"), task.title, t.title))
                }
            })

        case .copy:
            return .action(key, String(localized: "ctx.subtask.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.title, forType: .string)
            }

        case .copyLink:
            return .action(key, String(localized: "ctx.task.copylink")) { copyLink(id) }

        case .delete:
            return .action(key, String(localized: "common.delete"), destructive: true) {
                let next = model.selectedTaskID == id ? ListCompletion.neighbourToSelect(after: id, model: model) : nil
                store.softDelete(id)
                if let next { model.selectedTaskID = next }
                model.commit(String(format: String(localized: "undo.deleted.name"), task.title))
            }
        }
    }

    /// One-line glosses for the two statuses whose meaning is not obvious.
    private static func statusHelp(_ status: KStatus) -> String? {
        switch status {
        case .waiting: return String(localized: "ctx.task.waiting.help")
        case .someday: return String(localized: "ctx.task.someday.help")
        default: return nil
        }
    }

    /// The `kronos://open?id=` link of a task, as a URL and as text, so Notes, Mail and a text field
    /// each take what suits them. Nothing in the store changes, so nothing is pushed to undo.
    static func copyLink(_ id: UUID, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(TaskLink.string(for: id), forType: .URL)
        pasteboard.setString(TaskLink.string(for: id), forType: .string)
    }

    /// The date choices every date menu offers: Today · Tomorrow · Next week · Pick… · Clear.
    /// Clear is built disabled when there is no date (the renderer hides it).
    private static func dueNodes(task: KTask, model: AppModel, pickDue: @escaping @MainActor () -> Void) -> [CtxNode] {
        let store = model.store
        let id = task.id
        let today = Day.today()
        func quick(_ nodeID: String, _ title: String, _ day: Int) -> CtxNode {
            .action(nodeID, title, checked: task.dueDay == day) {
                guard task.dueDay != day else { return }
                store.setDue(id, day: day)
                model.commit(ListPills.due(day, title: task.title))
            }
        }
        return [
            quick("due.today",
                  String(localized: "deadline.quick.today"), today),
            quick("due.tomorrow",
                  String(localized: "deadline.quick.tomorrow"), today + 1),
            quick("due.nextweek",
                  String(localized: "deadline.quick.nextweek"), today + 7),
            .action("due.pick",
                    String(localized: "ctx.field.pick"), pickDue),
            .divider("due.div"),
            .action("due.clear",
                    String(localized: "ctx.field.clear"), enabled: task.dueDay != nil) {
                guard task.dueDay != nil else { return }
                store.setDue(id, day: nil)
                model.commit(ListPills.due(nil, title: task.title))
            },
        ]
    }
}

/// Pill texts shared by the row, its menu, the date field and the keys.
@MainActor
enum ListPills {
    static func due(_ day: Int?, title: String) -> String {
        guard let day else { return String(format: String(localized: "list.pill.dueclear"), title) }
        return String(format: String(localized: "list.pill.due"), ViewOptionsMapper.mediumDate(day), title)
    }
}

/// Pin as focus / Unpin focus, one implementation for the F key and the row menu. The pin is UI
/// state, not a store write: its pill carries its own undo.
@MainActor
enum ListFocusPin {
    static func toggle(_ id: UUID, title: String, model: AppModel) {
        let previous = model.pinnedFocusTaskID
        if previous == id {
            model.pinnedFocusTaskID = nil
            UndoToastCenter.shared.show(String(format: String(localized: "undo.unpinned.name"), title),
                                        customUndo: { [model] in model.pinnedFocusTaskID = id })
        } else {
            model.pinnedFocusTaskID = id
            UndoToastCenter.shared.show(String(format: String(localized: "undo.pinned.name"), title),
                                        customUndo: { [model] in model.pinnedFocusTaskID = previous })
        }
    }
}

// MARK: - Attachment

extension View {
    /// The context menu of a top-level task row. `pickDue` opens the row's own date field.
    func kTaskContextMenu(_ task: KTask, model: AppModel,
                          onSelect: @escaping @MainActor () -> Void,
                          pickDue: @escaping @MainActor () -> Void) -> some View {
        kContextMenu(id: "row.\(task.id.uuidString)") {
            TaskMenu.nodes(task: task, model: model, pickDue: pickDue, onSelect: onSelect)
        }
    }
}
