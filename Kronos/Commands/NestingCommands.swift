// Kronos/Commands/NestingCommands.swift
// The Task menu: Cmd-] / Cmd-[. Bindings come from HotkeyRegistry ("window.nest",
// "window.unnest"); the OptionChordMonitor fires these same items for the Croatian layout,
// where the brackets are behind AltGr (see OptionChordDecider).
import SwiftUI

struct NestingCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu(String(localized: "menu.task.title")) {
            Button(String(localized: "menu.task.nest")) {
                NestingActions.nestSelected(model: model)
            }
            .hotkey("window.nest")

            Button(String(localized: "menu.task.unnest")) {
                NestingActions.promoteFocused(model: model)
            }
            .hotkey("window.unnest")
        }
    }
}
