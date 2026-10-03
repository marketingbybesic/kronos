// Kronos/Palette/PaletteCommands.swift
// The command registry: every non-task-search row the palette can show, plus the keymap
// reference sheet's Global/View/Session rows. Adding a command means adding one entry here —
// nothing else in Kronos/Palette needs to change.
//
// Execution goes through two paths, per the brief:
//  - notifications the shell (Kronos/App) already posts/observes (menu-driven actions), or
//  - direct AppModel / TaskStoring calls for state this leaf can reach on its own.
// Rows that act on the task in the inspector live in PaletteTaskCommands.swift. Every key cap is
// read from HotkeyRegistry through `registryID`; no row carries a literal shortcut.
import Foundation
import KronosCore

@MainActor
enum PaletteCommands {
    /// Fixed scopes in their ⌘1…⌘6 order, each with its own Go-to command.
    private static let scopeShortcuts: [String] = ["1", "2", "3", "4", "5", "6"]

    static func all(model: AppModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        commands += bulkCommands(model: model)
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

    // MARK: Bulk — only while the list holds a multi-selection (`model.selectedIDs`, 2+ rows).
    // Same `ListBulk.apply` the floating bar uses, so one undo step per command. Titles carry
    // the count through literal one/few/many keys (Croatian needs three forms).

    private static func bulkCommands(model: AppModel) -> [PaletteCommand] {
        let n = model.selectedIDs.count
        guard n > 1 else { return [] }
        let today = Day.today(calendar: KronosLocale.calendar)
        func command(_ id: String, _ title: String, _ glyph: String, _ change: ListBulk.Change) -> PaletteCommand {
            PaletteCommand(id: "bulk.\(id)", literalTitle: title, glyph: glyph, group: .bulk,
                            isAvailable: { $0.selectedIDs.count > 1 }) { ListBulk.apply(change, model: $0) }
        }
        var rows: [PaletteCommand] = [
            command("complete", plural(n, one: String(localized: "palette.bulk.complete.one"),
                                       few: String(localized: "palette.bulk.complete.few"),
                                       many: String(localized: "palette.bulk.complete.many"), nil),
                    "check-square", .toggleDone),
        ]
        let dueTitle = { (name: String) in
            plural(n, one: String(localized: "palette.bulk.due.one"), few: String(localized: "palette.bulk.due.few"),
                   many: String(localized: "palette.bulk.due.many"), name)
        }
        for (id, name, day) in [("today", String(localized: "deadline.quick.today"), today),
                                ("tomorrow", String(localized: "deadline.quick.tomorrow"), today + 1),
                                ("nextweek", String(localized: "deadline.quick.nextweek"), today + 7)] {
            rows.append(command("due." + id, dueTitle(name), "calendar", .due(day)))
        }
        for p in KPriority.allCases {
            rows.append(command("priority.\(p.rawValue)",
                                plural(n, one: String(localized: "palette.bulk.priority.one"),
                                       few: String(localized: "palette.bulk.priority.few"),
                                       many: String(localized: "palette.bulk.priority.many"), ViewOptionsMapper.priorityName(p)),
                                "flag", .priority(p)))
        }
        for project in model.store.allProjects() {
            rows.append(command("move.\(project.id)",
                                plural(n, one: String(localized: "palette.bulk.move.one"),
                                       few: String(localized: "palette.bulk.move.few"),
                                       many: String(localized: "palette.bulk.move.many"), project.name),
                                "folder", .project(project)))
        }
        // Delete is LAST in the group, so Down+Return from the top can never delete (audit D14).
        rows.append(command("delete", plural(n, one: String(localized: "palette.bulk.delete.one"),
                                             few: String(localized: "palette.bulk.delete.few"),
                                             many: String(localized: "palette.bulk.delete.many"), nil),
                            "x", .delete))
        return rows
    }

    /// Picks the CLDR category's literal pattern; `%1$lld` is the count, `%2$@` the optional name.
    private static func plural(_ n: Int, one: String, few: String, many: String, _ name: String?) -> String {
        let pattern: String
        switch KPluralCategory.category(for: n, isCroatian: KronosLocale.languageCode == "hr") {
        case .one: pattern = one
        case .few: pattern = few
        case .many: pattern = many
        }
        return String(format: pattern, n, name ?? "")
    }

    // MARK: Create

    private static var createCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "create.task", titleKey: "list.new", glyph: "plus",
                            registryID: "window.newtask", group: .create) { _ in
                NotificationCenter.default.post(name: .kronosNewTaskRequested, object: nil)
            },
            PaletteCommand(id: "create.fromtemplate", titleKey: "palette.template.new", glyph: "plus",
                            group: .create) { _ in
                NotificationCenter.default.post(name: Notification.Name("kronosNewFromTemplate"), object: nil)
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
                                        group: .coach, isAvailable: { $0.inspectedTask?.isSubtask == false }) { model in
            guard let id = model.inspectedTaskID else { return }
            AppDelegate.shared?.autoTriage?.triage(id, fillOnly: true)
        })
        commands.append(PaletteCommand(id: "coach.pullnotes", titleKey: "palette.command.pullnotes", glyph: "download",
                                        group: .coach) { _ in
            NotificationCenter.default.post(name: .kronosPullFromNotesRequested, object: nil)
        })
        commands.append(PaletteCommand(id: "coach.linknote", titleKey: "palette.command.linknote", glyph: "link",
                                        group: .coach, isAvailable: { $0.inspectedTaskID != nil }) { model in
            guard let id = model.inspectedTaskID else { return }
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
        // Going to a list persists it like the Go menu does, so the next launch opens there.
        var items: [PaletteCommand] = zip(ListScope.fixed, scopeShortcuts).map { scope, digit in
            PaletteCommand(id: "goto.\(scope.storageKey)", titleKey: scope.titleKey ?? "sidebar.all",
                            glyph: goToGlyph(scope), registryID: "window.goto.\(digit)", group: .goTo) { model in
                model.scope = scope
                model.persist()
            }
        }
        items += model.store.allProjects().map { project in
            let name = project.area.map { "\($0.name) / \(project.name)" } ?? project.name
            return PaletteCommand(id: "goto.project.\(project.id)", literalTitle: name, glyph: "folder",
                                   projectIcon: project.icon, projectColorHex: project.colorHex,
                                   group: .goTo) { model in
                model.scope = .project(project.id)
                model.persist()
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
                            registryID: "window.find", group: .view) { _ in
                NotificationCenter.default.post(name: .kronosFocusSearchRequested, object: nil)
            },
            PaletteCommand(id: "view.options", titleKey: "list.display", glyph: "sliders",
                            registryID: "window.viewoptions", group: .view) { _ in
                NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
            },
            PaletteCommand(id: "view.toggleinspector", titleKey: "menu.view.inspector", glyph: "panel-right",
                            registryID: "window.inspector", group: .view) { _ in
                NotificationCenter.default.post(name: .kronosToggleInspectorRequested, object: nil)
            },
            PaletteCommand(id: "view.togglesidebar", titleKey: "menu.view.sidebar", glyph: "panel-right",
                            registryID: "window.sidebar", group: .view) { model in
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
        let registryIDs: [ChromaMode: String] = [.focus: "window.chroma.focus", .full: "window.chroma.full"]
        return ChromaMode.allCases.compactMap { mode in
            guard let registryID = registryIDs[mode] else { return nil }
            return PaletteCommand(id: "chroma.\(mode.rawValue)", literalTitle: KChromaModeSwitch.name(mode),
                                   glyph: KChromaModeSwitch.icon(mode), registryID: registryID, group: .view,
                                   isAvailable: { $0.chromaMode != mode }) { model in
                model.chromaMode = mode
            }
        }
    }

    // MARK: Session

    private static var sessionCommands: [PaletteCommand] {
        [
            // Pick one's real binding is the registry's `window.impuls` (⇧⌘I by default; ⌘I is the
            // inspector). Read live, so a rebind in Settings shows here too, never a stale cap.
            PaletteCommand(id: "session.impuls", titleKey: "menu.task.impuls", glyph: "sparkles",
                            registryID: "window.impuls", group: .session) { model in
                model.isImpulsOpen = true
            },
            // Up next: the menu bar popover with the task to do now (the global "show" key).
            PaletteCommand(id: "session.upnext", titleKey: "hotkey.global.showordo", glyph: "target",
                            registryID: "global.showordo", group: .session) { _ in
                NotificationCenter.default.post(name: .kronosShowOrdoRequested, object: nil)
            },
            // Reopens the inline Morning plan above Today (the shell observes the request).
            PaletteCommand(id: "session.morningplan", titleKey: "menu.task.morning", glyph: "sun",
                            group: .session) { model in
                model.scope = .today
                NotificationCenter.default.post(name: .kronosMorningPlanRequested, object: nil)
            },
            PaletteCommand(id: "session.triage", titleKey: "menu.task.triage", glyph: "check-square",
                            registryID: "window.triage", group: .session) { model in
                model.isTriageOpen = true
            },
            // Sweep: the same card flow over what has gone quiet. The mode is requested first;
            // a card already open switches in place, a closed one reads it when it appears.
            PaletteCommand(id: "session.sweep", titleKey: "sweep.command", glyph: "archive",
                            group: .session) { model in
                TriageLaunch.shared.request(.sweep)
                model.isTriageOpen = true
            },
            PaletteCommand(id: "session.capture", titleKey: "menu.task.capture", glyph: "clipboard",
                            registryID: "window.capture", group: .session) { model in
                model.isCaptureOpen = true
            },
            // HotkeyRegistry entry `window.timeblocks` (⌥⌘B, unclaimed) + the KronosApp.swift
            // menu item live in Kronos/Hotkeys/** and KronosApp.swift. Only reachable once
            // Time Blocks is turned on in Settings, same gating the sidebar row uses.
            PaletteCommand(id: "session.timeblocks", titleKey: "timeblocks.title", glyph: "calendar",
                            registryID: "window.timeblocks", group: .session,
                            isAvailable: { _ in TimeBlocksPrefs.isEnabled }) { model in
                model.isTimeBlocksOpen = true
            },
        ]
    }

    // MARK: App

    private static var appCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "app.undo", titleKey: "menu.edit.undo", glyph: "arrow-up",
                            registryID: "window.undo", group: .app, isAvailable: { $0.store.canUndo }) { model in
                PaletteCommit.run(model) { model.store.undo() }
            },
            PaletteCommand(id: "app.redo", titleKey: "menu.edit.redo", glyph: "arrow-up",
                            registryID: "window.redo", group: .app, isAvailable: { $0.store.canRedo }) { model in
                PaletteCommit.run(model) { model.store.redo() }
            },
        ]
    }

}
