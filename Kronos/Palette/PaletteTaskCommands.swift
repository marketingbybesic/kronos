// Kronos/Palette/PaletteTaskCommands.swift
// Rows that act on THE task the inspector shows (the inspected child in child mode, else the
// selected task), so a command always acts on what the person is looking at. With 2+ rows
// selected the bulk group takes over instead (PaletteCommands.bulkCommands).
//
// Naming follows the context menu and the list keys: Complete, Pin as focus, and the date
// vocabulary Today, Tomorrow, Next week, Pick…, Clear (each carries "Due date" as its qualifier).
// Every write goes through `PaletteCommit`, so each one raises the undo pill.
import Foundation
import KronosCore

extension PaletteCommands {
    static var taskCommands: [PaletteCommand] {
        let hasSelection: (AppModel) -> Bool = { $0.inspectedTaskID != nil && $0.selectedIDs.count < 2 }
        // Breaking down, moving, duplicating and re-triage are for top-level tasks: a child has no
        // children, lives in its parent's project and is never triaged.
        let hasTopLevel: (AppModel) -> Bool = { hasSelection($0) && $0.inspectedTask?.isSubtask == false }
        let isDone: (AppModel) -> Bool = { $0.inspectedTask?.status == .done }
        var rows: [PaletteCommand] = [
            PaletteCommand(id: "task.complete", titleKey: "bar.menu.complete", glyph: "check-square",
                           registryID: "list.toggle", group: .selected,
                           isAvailable: { hasSelection($0) && !isDone($0) }) { model in
                // The same completion the list runs: the selection moves to the next row and the pill
                // offers the next task.
                guard let id = model.inspectedTaskID, let task = model.store.task(id) else { return }
                ListCompletion.toggle(task, store: model.store, model: model)
            },
            PaletteCommand(id: "task.reopen", titleKey: "ctx.task.undone", glyph: "check",
                           registryID: "list.toggle", group: .selected,
                           isAvailable: { hasSelection($0) && isDone($0) }) { model in
                guard let id = model.inspectedTaskID, let task = model.store.task(id) else { return }
                ListCompletion.toggle(task, store: model.store, model: model)
            },
            PaletteCommand(id: "task.snooze", titleKey: "ctx.task.snooze", glyph: "clock",
                           registryID: "list.snooze", group: .selected, isAvailable: hasSelection) { model in
                guard let id = model.inspectedTaskID, let title = model.store.task(id)?.title else { return }
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "undo.snoozed.name"), title)) {
                    model.store.snooze(id)
                }
            },
        ]
        rows += priorityRows(hasSelection)
        rows += effortRows(hasSelection)
        rows += dateRows(hasSelection)
        rows += statusRows(hasSelection)
        rows += [
            PaletteCommand(id: "task.moveto", titleKey: "palette.task.moveto", glyph: "folder",
                           keepsOpen: true, group: .selected, isAvailable: hasTopLevel) { model in
                guard let id = model.inspectedTaskID else { return }
                PalettePromptCenter.shared.request(.moveTo(id))
            },
            PaletteCommand(id: "task.rename", titleKey: "palette.task.rename", glyph: "pencil",
                           keepsOpen: true, group: .selected, isAvailable: hasSelection) { model in
                guard let id = model.inspectedTaskID else { return }
                PalettePromptCenter.shared.request(.rename(id))
            },
            PaletteCommand(id: "task.duplicate", titleKey: "ctx.task.duplicate", glyph: "copy",
                           group: .selected, isAvailable: hasTopLevel) { model in
                guard let id = model.inspectedTaskID else { return }
                PaletteCommit.duplicate(id, model: model)
            },
            PaletteCommand(id: "task.copylink", titleKey: "ctx.task.copylink", glyph: "link",
                           group: .selected, isAvailable: hasSelection) { model in
                guard let id = model.inspectedTaskID else { return }
                PaletteCommit.copyLink(id)
            },
            PaletteCommand(id: "task.retriage", titleKey: "menu.task.retriage", glyph: "sparkles",
                           group: .selected, isAvailable: { hasTopLevel($0) && $0.inspectedTask?.needsTriage == false }) { model in
                guard let id = model.inspectedTaskID, let title = model.store.task(id)?.title else { return }
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "palette.undo.resort"), title)) {
                    model.store.update(id) { $0.needsTriage = true }
                }
            },
            // ⌦ is the list's own delete key.
            PaletteCommand(id: "task.delete", titleKey: "ctx.task.delete", glyph: "x",
                           registryID: "list.delete", group: .selected, isAvailable: hasSelection) { model in
                guard let id = model.inspectedTaskID, let title = model.store.task(id)?.title else { return }
                let wasChild = model.inspectedTask?.isSubtask == true
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "undo.deleted.name"), title)) {
                    model.store.softDelete(id)
                    // A deleted child leaves the inspector on its parent; a deleted task clears the selection.
                    if wasChild { model.closeChildDetails() } else { model.selectedTaskID = nil }
                }
            },
            // Opens the task and asks its steps section for the break-down preview. Nothing is
            // decomposed here: the person sees the proposal first and accepts it with ⌘⏎.
            PaletteCommand(id: "task.breakdown", titleKey: "ctx.task.breakdown", glyph: "sparkles",
                           group: .selected, isAvailable: hasTopLevel) { model in
                guard let id = model.inspectedTaskID else { return }
                model.selectedTaskID = id
                BreakdownRequests.shared.request(taskID: id)
            },
            // Toggled on the inspected task itself (not `focusTaskID`, which may be the automatic
            // pick with nothing pinned), so "Pin as focus" always means THIS task.
            PaletteCommand(id: "task.pin", titleKey: "palette.command.pin", glyph: "target",
                           registryID: "list.focuspin", group: .selected,
                           isAvailable: { model in
                               guard let id = model.inspectedTaskID else { return false }
                               return model.pinnedFocusTaskID != id
                           }) { model in
                guard let id = model.inspectedTaskID, let title = model.store.task(id)?.title else { return }
                let before = model.pinnedFocusTaskID
                model.pinnedFocusTaskID = id
                UndoToastCenter.shared.show(PaletteCommit.text(String(localized: "undo.pinned.name"), title),
                                            customUndo: { model.pinnedFocusTaskID = before })
            },
            PaletteCommand(id: "task.unpin", titleKey: "palette.command.unpin", glyph: "target",
                           registryID: "list.focuspin", group: .selected,
                           isAvailable: { model in
                               guard let id = model.inspectedTaskID else { return false }
                               return model.pinnedFocusTaskID == id
                           }) { model in
                guard let id = model.inspectedTaskID, let title = model.store.task(id)?.title else { return }
                let before = model.pinnedFocusTaskID
                model.pinnedFocusTaskID = nil
                UndoToastCenter.shared.show(PaletteCommit.text(String(localized: "undo.unpinned.name"), title),
                                            customUndo: { model.pinnedFocusTaskID = before })
            },
        ]
        return ordered(rows)
    }

    /// The order the rows read in with an empty query (only the first few show): what is done most,
    /// then the second steps, dates, status, priority and effort, and Delete always last.
    private static let taskRowOrder = [
        "task.complete", "task.reopen", "task.pin", "task.unpin", "task.snooze", "task.moveto", "task.rename",
        "task.deadline.today", "task.deadline.tomorrow", "task.deadline.nextweek", "task.pickdate", "task.deadline.none",
        "task.waiting", "task.someday", "task.priority.", "task.effort.", "task.duplicate", "task.copylink",
        "task.breakdown", "task.retriage", "task.delete",
    ]

    private static func ordered(_ rows: [PaletteCommand]) -> [PaletteCommand] {
        func rank(_ id: String) -> Int {
            taskRowOrder.firstIndex { id == $0 || ($0.hasSuffix(".") && id.hasPrefix($0)) } ?? taskRowOrder.count
        }
        return rows.enumerated()
            .sorted { rank($0.element.id) != rank($1.element.id) ? rank($0.element.id) < rank($1.element.id) : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: Priority, effort

    private static func priorityRows(_ hasSelection: @escaping (AppModel) -> Bool) -> [PaletteCommand] {
        let table: [(KPriority, id: String, titleKey: String, registryID: String)] = [
            (.urgent, "urgent", "priority.urgent", "list.priority.urgent"),
            (.high, "high", "priority.high", "list.priority.high"),
            (.medium, "medium", "priority.medium", "list.priority.medium"),
            (.low, "low", "priority.low", "list.priority.low"),
            (.none, "none", "priority.none", "list.priority.none"),
        ]
        return table.map { p, id, titleKey, registryID in
            PaletteCommand(id: "task.priority.\(id)", titleKey: titleKey, glyph: "flag",
                           registryID: registryID, detailKey: "ctx.task.priority", group: .selected,
                           isAvailable: hasSelection) { model in
                guard let taskID = model.inspectedTaskID, let task = model.store.task(taskID),
                      task.priorityRaw != p.rawValue else { return }
                let name = ViewOptionsMapper.priorityName(p)
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "undo.priority.name"), name, task.title)) {
                    model.store.setPriority(taskID, p)
                }
            }
        }
    }

    private static func effortRows(_ hasSelection: @escaping (AppModel) -> Bool) -> [PaletteCommand] {
        let table: [(KEffort, id: String, titleKey: String)] = [
            (.xs, "xs", "effort.xs"), (.s, "s", "effort.s"), (.m, "m", "effort.m"), (.l, "l", "effort.l"), (.xl, "xl", "effort.xl"),
        ]
        return table.map { effort, id, titleKey in
            PaletteCommand(id: "task.effort.\(id)", titleKey: titleKey, glyph: "sliders",
                           detailKey: "ctx.task.effort", group: .selected, isAvailable: hasSelection) { model in
                guard let taskID = model.inspectedTaskID, let task = model.store.task(taskID),
                      task.effortRaw != effort.rawValue else { return }
                let name = ViewOptionsMapper.effortName(effort)
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "palette.undo.effort"), task.title, name)) {
                    model.store.setEffort(taskID, effort)
                }
            }
        }
    }

    // MARK: Dates

    private static func dateRows(_ hasSelection: @escaping (AppModel) -> Bool) -> [PaletteCommand] {
        func quick(_ id: String, _ titleKey: String, offset: Int) -> PaletteCommand {
            PaletteCommand(id: "task.deadline.\(id)", titleKey: titleKey, glyph: "calendar",
                           detailKey: "ctx.task.due", group: .selected, isAvailable: hasSelection) { model in
                guard let taskID = model.inspectedTaskID, let task = model.store.task(taskID) else { return }
                let day = Day.today(calendar: KronosLocale.calendar) + offset
                guard task.dueDay != day else { return }
                let name = String(localized: String.LocalizationValue(titleKey))
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "palette.undo.due"), task.title, name)) {
                    model.store.setDue(taskID, day: day)
                }
            }
        }
        return [
            quick("today", "deadline.quick.today", offset: 0),
            quick("tomorrow", "deadline.quick.tomorrow", offset: 1),
            quick("nextweek", "deadline.quick.nextweek", offset: 7),
            PaletteCommand(id: "task.pickdate", titleKey: "ctx.field.pick", glyph: "calendar",
                           detailKey: "ctx.task.due", keepsOpen: true, group: .selected, isAvailable: hasSelection) { model in
                guard let id = model.inspectedTaskID else { return }
                PalettePromptCenter.shared.request(.pickDate(id))
            },
            PaletteCommand(id: "task.deadline.none", titleKey: "ctx.field.clear", glyph: "calendar",
                           detailKey: "ctx.task.due", group: .selected,
                           isAvailable: { hasSelection($0) && $0.inspectedTask?.dueDay != nil }) { model in
                guard let id = model.inspectedTaskID, let task = model.store.task(id), task.dueDay != nil else { return }
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "palette.undo.duecleared"), task.title)) {
                    model.store.setDue(id, day: nil)
                }
            },
        ]
    }

    // MARK: Status

    private static func statusRows(_ hasSelection: @escaping (AppModel) -> Bool) -> [PaletteCommand] {
        func row(_ id: String, _ status: KStatus, titleKey: String) -> PaletteCommand {
            PaletteCommand(id: "task.\(id)", titleKey: titleKey, glyph: status == .waiting ? "hourglass" : "archive",
                           detailKey: "ctx.task.status", group: .selected,
                           isAvailable: { hasSelection($0) && $0.inspectedTask?.status != status }) { model in
                guard let taskID = model.inspectedTaskID, let task = model.store.task(taskID), task.status != status else { return }
                let name = String(localized: String.LocalizationValue(titleKey))
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "palette.undo.status"), task.title, name)) {
                    model.store.setStatus(taskID, status)
                }
            }
        }
        return [row("waiting", .waiting, titleKey: "sidebar.waiting"),
                row("someday", .someday, titleKey: "sidebar.someday")]
    }
}
