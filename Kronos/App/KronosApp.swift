import SwiftUI
import AppKit
import KronosCore

@main
struct KronosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Kronos", id: "main") {
            AppShellView(model: appDelegate.model)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
                .background(Tok.bg.ignoresSafeArea())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            KronosCommands(model: appDelegate.model)
            CommandGroup(replacing: .help) {
                Button(String(localized: "welcome.menu.tour")) {
                    TourCenter.shared.start(model: appDelegate.model)
                }
                Button(String(localized: "welcome.menu.starthere")) {
                    OnboardingCenter.shared.reopen(model: appDelegate.model)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button(String(localized: "welcome.menu.show")) {
                    WelcomeWindowController.show()
                }
                Button(String(localized: "welcome.menu.github")) {
                    guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil,
                          let url = URL(string: "https://github.com/marketingbybesic/kronos") else { return }
                    NSWorkspace.shared.open(url)
                }
            }
        }

        Settings {
            SettingsScreen(model: appDelegate.model)
        }
        .defaultSize(width: 900, height: 640)
    }
}

/// The app's menu-bar command surface. A separate type (not inline in `.commands {}`) so the
/// notification-posting glue is unit-legible and the model reference is captured once.
///
/// Every `.hotkey(id)` below reads its binding from `HotkeyRegistry` (Kronos/Hotkeys/) — the
/// single source of truth for every shortcut in the app; see that file for the full table and
/// for `scripts/verify-hotkeys.mjs`, which fails the build if a literal here drifts from it.
/// Notification names are declared in AppNotifications.swift; observers elsewhere in the app
/// match those exact raw strings.
private struct KronosCommands: Commands {
    let model: AppModel
    /// `.hotkey(id)` reads the registry when this body is evaluated; without a dependency on
    /// something that changes, a rebind in Settings left the menu showing the old key until relaunch.
    @State private var hotkeyTick = HotkeyTick()

    var body: some Commands {
        let _ = hotkeyTick.count
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "menu.file.newtask")) {
                NotificationCenter.default.post(name: .kronosNewTaskRequested, object: nil)
            }
            .hotkey("window.newtask")
        }

        CommandGroup(after: .textEditing) {
            Divider()
            // This posts kronosFocusSearchRequested (TaskListScreen focuses its search
            // field), not quick-add — "sidebar.search.placeholder" ("Search") is the
            // closest existing key to that action. No dedicated "menu.edit.find" key
            // exists in the catalog.
            Button(String(localized: "menu.edit.find")) {
                NotificationCenter.default.post(name: .kronosFocusSearchRequested, object: nil)
            }
            .hotkey("window.find")
        }

        CommandGroup(replacing: .undoRedo) {
            // Never `.disabled(!canUndo)`: the store is not observable from a Commands body, so
            // the item would be evaluated once with an empty stack and stay greyed out for
            // good. Undo has no time limit; only the pill expires.
            Button(String(localized: "menu.edit.undo")) {
                // A custom-undo pill (pin/unpin) owns Cmd-Z while it is up.
                if UndoToastCenter.shared.performCustomUndo() { return }
                // While typing, Cmd-Z belongs to the text field — unless the undo pill is up: the
                // user just completed/moved something and the pill promises that Cmd-Z undoes
                // IT, not the last keystroke in a field that still holds focus (live test 30.09.:
                // completing a row after typing a subtask left the task done and undid the text).
                if UndoToastCenter.shared.current == nil,
                   let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
                    text.undoManager?.undo()
                } else {
                    model.store.undo()
                    model.didMutate()
                }
            }
            .hotkey("window.undo")

            Button(String(localized: "menu.edit.redo")) {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
                    text.undoManager?.redo()
                } else {
                    model.store.redo()
                    model.didMutate()
                }
            }
            .hotkey("window.redo")
        }

        CommandGroup(after: .toolbar) {
            // This posts kronosViewOptionsRequested, which opens the view-options popover
            // (TaskListScreen) — "viewoptions.title" ("View options") is that popover's own
            // title key; "menu.view.showdone" ("Show Done") names an unrelated toggle.
            Button(String(localized: "viewoptions.title")) {
                NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
            }
            .hotkey("window.viewoptions")

            Divider()

            Button(String(localized: "menu.view.inspector")) {
                NotificationCenter.default.post(name: .kronosToggleInspectorRequested, object: nil)
            }
            .hotkey("window.inspector")

            Button(String(localized: "menu.view.sidebar")) {
                model.sidebarIconsOnly.toggle()
                model.persist()
            }
            .hotkey("window.sidebar")

            Divider()

            // Colour modes: one keystroke to match the UI to your state.
            Button(String(localized: "chroma.mode.focus")) { model.chromaMode = .focus }
                .hotkey("window.chroma.focus")
            Button(String(localized: "chroma.mode.full")) { model.chromaMode = .full }
                .hotkey("window.chroma.full")

            Divider()

            Button(String(localized: "menu.task.impuls")) {
                model.isImpulsOpen = true
            }
            .hotkey("window.impuls")

            Button(String(localized: "menu.task.triage")) {
                model.isTriageOpen = true
            }
            .hotkey("window.triage")

            Button(String(localized: "menu.task.capture")) {
                model.isCaptureOpen = true
            }
            .hotkey("window.capture")

            Button(String(localized: "menu.view.palette")) {
                model.isPaletteOpen = true
            }
            .hotkey("window.palette")

            Button(String(localized: "settings.shortcuts.all")) {
                NotificationCenter.default.post(name: .kronosKeymapRequested, object: nil)
            }
            .hotkey("window.keymap")

            Button(String(localized: "timeblocks.title")) {
                model.isTimeBlocksOpen = true
            }
            .hotkey("window.timeblocks")
        }

        CommandMenu(String(localized: "menu.go.title")) {
            ForEach(Array(ListScope.fixed.enumerated()), id: \.offset) { index, scope in
                if let key = scope.titleKey {
                    Button(String(localized: String.LocalizationValue(key))) {
                        model.scope = scope
                        model.persist()
                    }
                    .hotkey("window.goto.\(index + 1)")
                }
            }
        }
    }
}

/// Bumps `count` whenever `HotkeyRegistry.changed` fires, so a Commands body that reads it rebuilds.
@MainActor @Observable
private final class HotkeyTick {
    var count = 0
    @ObservationIgnored private nonisolated(unsafe) var token: NSObjectProtocol?
    init() {
        // queue: .main: the notification can be posted from any thread (selector observers run on the poster).
        token = NotificationCenter.default.addObserver(forName: HotkeyRegistry.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
