// Kronos/Palette/PaletteCommands.swift
// The command registry: every non-task-search row the palette can show, plus the keymap
// reference sheet's Global/View/Session rows. Adding a command means adding one entry here —
// nothing else in Kronos/Palette needs to change.
//
// Execution goes through two paths, per the brief:
//  - notifications the shell (Kronos/App) already posts/observes (menu-driven actions), or
//  - direct AppModel / TaskStoring calls for state this leaf can reach on its own.
// Commands this leaf cannot fully wire (no highlighted/selected task concept exists in
// UIContract beyond `selectedTaskID`, no multi-selection) are scoped to what AppModel exposes;
// gaps are reported rather than invented.
import Foundation
import KronosCore

@MainActor
enum PaletteCommands {
    /// Fixed scopes in their ⌘1…⌘6 order, each with its own Go-to command.
    private static let scopeShortcuts: [String] = ["1", "2", "3", "4", "5", "6"]

    static func all(model: AppModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        commands += taskCommands
        commands += createCommands
        commands += coachCommands(model: model)
        commands += goToCommands(model: model)
        commands += viewCommands
        commands += sessionCommands
        commands += appCommands
        assertGlyphsResolve(commands)
        return commands
    }

    /// gate-app.mjs's Icon-name lint only sees a literal `Icon("name"` — every glyph here is
    /// a `String` stored on `PaletteCommand` and rendered via `Icon(command.glyph)`, which the
    /// lint's regex cannot see. This is the leaf's own check for that gap: an unmapped name
    /// silently falls back to Icon's "questionmark.folder" placeholder rather than failing to
    /// build, so debug builds assert loudly instead of shipping a wrong glyph quietly.
    private static func assertGlyphsResolve(_ commands: [PaletteCommand]) {
        #if DEBUG
        for c in commands {
            assert(Icon.symbol(for: c.glyph) != "questionmark.folder",
                   "PaletteCommand '\(c.id)' has unmapped glyph \"\(c.glyph)\" — add it to Icon.swift's map or pick an existing name")
        }
        #endif
    }

    // MARK: Task — applies to model.selectedTaskID (the contract's one notion of "current task")

    private static var taskCommands: [PaletteCommand] {
        let hasSelection: (AppModel) -> Bool = { $0.selectedTaskID != nil }
        return [
            // No shortcuts claimed on complete/snooze/priority/re-triage below: spec §2.2/§2.3
            // assigns ⌘⇧D, H, 0-4, ⌘R as list-scope single-key shortcuts, but TaskListScreen.swift
            // only actually wires ↑/↓/Space/⌦ — the rest were never implemented. Listing an
            // unregistered key in the keymap sheet would show something that does not fire.
            PaletteCommand(id: "task.complete", titleKey: "ctx.task.done", glyph: "check-square",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID, let title = model.store.task(id)?.title else { return }
                model.store.complete(id); model.didMutate()
                // Shell-level pill (KUndoPill.swift / AppShellView): undo pill everywhere.
                UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), title))
            },
            PaletteCommand(id: "task.reopen", titleKey: "ctx.task.undone", glyph: "check",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID, let title = model.store.task(id)?.title else { return }
                model.store.reopen(id); model.didMutate()
                UndoToastCenter.shared.show(String(format: String(localized: "undo.uncompleted.name"), title))
            },
            PaletteCommand(id: "task.snooze", titleKey: "ctx.task.snooze", glyph: "clock",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.snooze(id); model.didMutate()
            },
            PaletteCommand(id: "task.priority.urgent", titleKey: "priority.urgent", glyph: "flag",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setPriority(id, .urgent); model.didMutate()
            },
            PaletteCommand(id: "task.priority.high", titleKey: "priority.high", glyph: "flag",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setPriority(id, .high); model.didMutate()
            },
            PaletteCommand(id: "task.priority.medium", titleKey: "priority.medium", glyph: "flag",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setPriority(id, .medium); model.didMutate()
            },
            PaletteCommand(id: "task.priority.low", titleKey: "priority.low", glyph: "flag",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setPriority(id, .low); model.didMutate()
            },
            PaletteCommand(id: "task.priority.none", titleKey: "priority.none", glyph: "flag",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setPriority(id, .none); model.didMutate()
            },
            PaletteCommand(id: "task.effort.xs", titleKey: "effort.xs", glyph: "sliders",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setEffort(id, .xs); model.didMutate()
            },
            PaletteCommand(id: "task.effort.s", titleKey: "effort.s", glyph: "sliders",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setEffort(id, .s); model.didMutate()
            },
            PaletteCommand(id: "task.effort.m", titleKey: "effort.m", glyph: "sliders",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setEffort(id, .m); model.didMutate()
            },
            PaletteCommand(id: "task.effort.l", titleKey: "effort.l", glyph: "sliders",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setEffort(id, .l); model.didMutate()
            },
            PaletteCommand(id: "task.effort.xl", titleKey: "effort.xl", glyph: "sliders",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setEffort(id, .xl); model.didMutate()
            },
            PaletteCommand(id: "task.deadline.today", titleKey: "deadline.quick.today", glyph: "calendar",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setDue(id, day: Day.today(calendar: KronosLocale.calendar)); model.didMutate()
            },
            PaletteCommand(id: "task.deadline.tomorrow", titleKey: "deadline.quick.tomorrow", glyph: "calendar",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                let today = Day.today(calendar: KronosLocale.calendar)
                model.store.setDue(id, day: today + 1); model.didMutate()
            },
            PaletteCommand(id: "task.deadline.none", titleKey: "deadline.quick.none", glyph: "calendar",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.setDue(id, day: nil); model.didMutate()
            },
            PaletteCommand(id: "task.retriage", titleKey: "menu.task.retriage", glyph: "sparkles",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.store.update(id) { $0.needsTriage = true }; model.didMutate()
            },
            // ⌦ IS real: TaskListScreen.swift wires `.onKeyPress(.deleteForward)` and
            // `.onKeyPress(.delete)` to delete the selection.
            PaletteCommand(id: "task.delete", titleKey: "ctx.task.delete", glyph: "x",
                            shortcut: ["⌦"], group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID, let title = model.store.task(id)?.title else { return }
                model.store.softDelete(id); model.selectedTaskID = nil; model.didMutate()
                UndoToastCenter.shared.show(String(format: String(localized: "undo.deleted.name"), title))
            },
            // "Break down" only opens the inspector on the selection — the inspector's own
            // Break down control (Kronos/Detail) is the one this file cannot reach from here
            // — so this command's whole job is making it "one click away", never invoking AI
            // decomposition itself.
            PaletteCommand(id: "task.breakdown", titleKey: "ctx.task.breakdown", glyph: "sparkles",
                            group: .task, isAvailable: hasSelection) { model in
                guard let id = model.selectedTaskID else { return }
                model.selectedTaskID = id
            },
            // "palette.command.pin"/"palette.command.unpin" are catalog keys. Toggled on the
            // selected task specifically (not `focusTaskID`, which may already be the
            // automatic Ordo pick with nothing pinned) so "Pin as focus" always means "pin
            // THIS task" and "Unpin" only appears once that same task is the pin.
            PaletteCommand(id: "task.pin", titleKey: "palette.command.pin",
                            glyph: "target", group: .task,
                            isAvailable: { model in
                                guard let id = model.selectedTaskID else { return false }
                                return model.pinnedFocusTaskID != id
                            }) { model in
                guard let id = model.selectedTaskID else { return }
                model.pinnedFocusTaskID = id
            },
            PaletteCommand(id: "task.unpin", titleKey: "palette.command.unpin",
                            glyph: "target", group: .task,
                            isAvailable: { model in
                                guard let id = model.selectedTaskID else { return false }
                                return model.pinnedFocusTaskID == id
                            }) { model in
                model.pinnedFocusTaskID = nil
            },
        ]
    }

    // MARK: Create

    private static var createCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "create.task", titleKey: "list.new", glyph: "plus",
                            shortcut: ["⌘", "N"], group: .create) { _ in
                NotificationCenter.default.post(name: .kronosNewTaskRequested, object: nil)
            },
        ]
    }

    // MARK: Coach — presets, re-triage, Notes, meeting capture, block Switch/Stay. Every string
    // is data-driven from Core (`OrdoPreset.name`) or the closest catalog key; none is invented
    // here.

    private static func coachCommands(model: AppModel) -> [PaletteCommand] {
        var commands = OrdoPreset.builtIns.map { preset in
            PaletteCommand(id: "coach.preset.\(preset.id)", titleKey: preset.name, glyph: "sparkles",
                            group: .coach) { model in
                model.coach.applyPreset(preset.id, to: model.scope)
            }
        }
        commands.append(PaletteCommand(id: "coach.retriage", titleKey: "menu.task.retriage", glyph: "sparkles",
                                        group: .coach, isAvailable: { $0.selectedTaskID != nil }) { model in
            guard let id = model.selectedTaskID else { return }
            AppDelegate.shared?.autoTriage?.triage(id, fillOnly: true)
        })
        // "palette.command.pullnotes" / "palette.command.linknote" / "palette.command.blockswitch" /
        // "palette.command.blockstay" now exist in the catalog (same pattern as
        // "palette.command.pin"/"unpin"). No existing key named these actions before that
        // (checked: "menu.task.sendordo" means "send 3 to Ordo", not "switch to this block's
        // project" — using it would show the wrong sentence). gate-app's string-key lint
        // hard-fails a literal `titleKey:` that is not cataloged, so these four used
        // `literalTitle` with plain EN text as a stopgap instead of either shipping broken or
        // deleting a built command. TODO: switch each to `titleKey:` now that the keys exist
        // (they currently lose HR until that happens).
        commands.append(PaletteCommand(id: "coach.pullnotes", titleKey: "palette.command.pullnotes", glyph: "download",
                                        group: .coach) { _ in
            NotificationCenter.default.post(name: .kronosPullFromNotesRequested, object: nil)
        })
        commands.append(PaletteCommand(id: "coach.linknote", titleKey: "palette.command.linknote", glyph: "link",
                                        group: .coach, isAvailable: { $0.selectedTaskID != nil }) { model in
            guard let id = model.selectedTaskID else { return }
            NotificationCenter.default.post(name: .kronosLinkNoteRequested, object: nil, userInfo: ["taskID": id])
        })
        commands.append(PaletteCommand(id: "coach.meetingcapture", titleKey: "hotkey.global.meetingcapture", glyph: "clock",
                                        group: .coach) { _ in
            NotificationCenter.default.post(name: .kronosMeetingCaptureRequested, object: nil)
        })
        commands.append(PaletteCommand(id: "coach.block.switch", titleKey: "palette.command.blockswitch", glyph: "arrow-right",
                                        group: .coach, isAvailable: { $0.coach.blockSuggestion != nil }) { model in
            model.coach.switchToBlock()
        })
        commands.append(PaletteCommand(id: "coach.block.stay", titleKey: "palette.command.blockstay", glyph: "check",
                                        group: .coach, isAvailable: { $0.coach.blockSuggestion != nil }) { model in
            model.coach.stayInCurrent()
        })
        return commands
    }

    // MARK: Go to — fixed scopes (⌘1…⌘6), then every non-archived project

    private static func goToCommands(model: AppModel) -> [PaletteCommand] {
        var items: [PaletteCommand] = zip(ListScope.fixed, scopeShortcuts).map { scope, digit in
            PaletteCommand(id: "goto.\(scope.storageKey)", titleKey: scope.titleKey ?? "sidebar.all",
                            glyph: goToGlyph(scope), shortcut: ["⌘", digit], group: .goTo) { model in
                model.scope = scope
            }
        }
        items += model.store.allProjects().map { project in
            let name = project.area.map { "\($0.name) / \(project.name)" } ?? project.name
            return PaletteCommand(id: "goto.project.\(project.id)", literalTitle: name, glyph: "folder",
                                   projectIcon: project.icon, projectColorHex: project.colorHex,
                                   group: .goTo) { model in
                model.scope = .project(project.id)
            }
        }
        // No shortcut claimed: ⌘, is not registered here. Add one if it should be.
        items.append(PaletteCommand(id: "goto.settings", titleKey: "sidebar.settings", glyph: "sliders",
                                     group: .goTo) { model in
            model.isPaletteOpen = false
            NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil)
        })
        return items
    }

    private static func goToGlyph(_ scope: ListScope) -> String {
        switch scope {
        case .inbox: return "inbox"
        case .today: return "sun"
        case .next7: return "calendar-days"
        case .waiting: return "hourglass"
        case .someday: return "archive"
        case .all: return "list-ordered"
        case .project, .area, .savedView: return "folder"
        }
    }

    // MARK: View — only meaningful once a list is open, which is always true here (no empty shell state)

    private static var viewCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "view.focussearch", titleKey: "sidebar.search.placeholder", glyph: "search",
                            shortcut: ["⌘", "F"], group: .view) { _ in
                NotificationCenter.default.post(name: .kronosFocusSearchRequested, object: nil)
            },
            PaletteCommand(id: "view.options", titleKey: "list.display", glyph: "sliders",
                            shortcut: ["⌥", "⌘", "F"], group: .view) { _ in
                NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
            },
            PaletteCommand(id: "view.toggleinspector", titleKey: "menu.view.inspector", glyph: "panel-right",
                            shortcut: ["⌘", "I"], group: .view) { _ in
                NotificationCenter.default.post(name: .kronosToggleInspectorRequested, object: nil)
            },
            PaletteCommand(id: "view.togglesidebar", titleKey: "menu.view.sidebar", glyph: "panel-right",
                            shortcut: ["⌘", "\\"], group: .view) { model in
                model.sidebarIconsOnly.toggle()
                model.persist()
            },
        ] + chromaCommands
    }

    /// Colour mode is data-driven, one row per `ChromaMode` case, each only listed once (a
    /// command for the mode already active would be a no-op row) — the real Ctrl-⌘-1/2/3
    /// registration lives in KronosApp.swift's app menu (this leaf cannot add a menu item),
    /// shown here purely as the key hint so the palette and the keymap sheet both stay
    /// truthful about what fires. `KChromaModeSwitch`'s own name/glyph helpers are reused so
    /// the palette row can never drift from Settings' General tab wording.
    private static var chromaCommands: [PaletteCommand] {
        let digits: [ChromaMode: String] = [.focus: "1", .full: "2", .calm: "3"]
        return ChromaMode.allCases.compactMap { mode in
            guard let digit = digits[mode] else { return nil }
            return PaletteCommand(id: "chroma.\(mode.rawValue)", literalTitle: KChromaModeSwitch.name(mode),
                                   glyph: KChromaModeSwitch.icon(mode), shortcut: ["⌃", "⌘", digit], group: .view,
                                   isAvailable: { $0.chromaMode != mode }) { model in
                model.chromaMode = mode
            }
        }
    }

    // MARK: Session

    private static var sessionCommands: [PaletteCommand] {
        [
            // Spec §2.1 assigns ⌘I to Impuls, but KronosApp.swift's actually-registered ⌘I opens
            // the inspector instead — no shortcut is claimed here so the keymap sheet does not
            // show a duplicate/incorrect ⌘I row.
            PaletteCommand(id: "session.impuls", titleKey: "menu.task.impuls", glyph: "sparkles",
                            group: .session) { model in
                model.isImpulsOpen = true
            },
            // KronosApp.swift registers ⌘⇧N on `model.isCaptureOpen = true` (Kronos/App menu
            // commands) — mirrored here with the same shortcut so the keymap sheet lists one
            // real binding, not two.
            PaletteCommand(id: "session.triage", titleKey: "menu.task.triage", glyph: "check-square",
                            shortcut: ["⌥", "⌘", "T"], group: .session) { model in
                model.isTriageOpen = true
            },
            PaletteCommand(id: "session.capture", titleKey: "menu.task.capture", glyph: "clipboard",
                            shortcut: ["⇧", "⌘", "N"], group: .session) { model in
                model.isCaptureOpen = true
            },
            // HotkeyRegistry entry `window.timeblocks` (⌥⌘B, unclaimed) + the KronosApp.swift
            // menu item live in Kronos/Hotkeys/** and KronosApp.swift. Only reachable once
            // Time Blocks is turned on in Settings, same gating the sidebar row uses.
            PaletteCommand(id: "session.timeblocks", titleKey: "timeblocks.title", glyph: "calendar",
                            shortcut: ["⌥", "⌘", "B"], group: .session,
                            isAvailable: { _ in TimeBlocksPrefs.isEnabled }) { model in
                model.isTimeBlocksOpen = true
            },
        ]
    }

    // MARK: App

    private static var appCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "app.undo", titleKey: "menu.edit.undo", glyph: "arrow-up",
                            shortcut: ["⌘", "Z"], group: .app, isAvailable: { $0.store.canUndo }) { model in
                model.store.undo(); model.didMutate()
            },
            PaletteCommand(id: "app.redo", titleKey: "menu.edit.redo", glyph: "arrow-up",
                            shortcut: ["⇧", "⌘", "Z"], group: .app, isAvailable: { $0.store.canRedo }) { model in
                model.store.redo(); model.didMutate()
            },
        ]
    }

}
