// Kronos/Intents/KronosShortcuts.swift. Natural-language phrases for Siri and Shortcuts, EN +
// HR, each containing `\(.applicationName)` (Apple requires it so Siri can disambiguate which
// app answers). AppShortcutsProvider is discovered automatically by the system at launch —
// nothing else needs to register it.
//
// Vocabulary: only the current words (Pick one, Up next) appear in the phrases. A saved shortcut keeps
// its intent whatever the phrases are, so the earlier names are not kept as extra phrases.
// The system allows at most 10 shortcuts: this provider uses all 10.

import AppIntents

struct KronosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsNextIntent(),
            phrases: [
                "What's next in \(.applicationName)",
                "What's up next in \(.applicationName)",
                "What should I do next in \(.applicationName)",
                "Sto je sljedece u \(.applicationName)",
                "Što je sljedeće u \(.applicationName)"
            ],
            shortTitle: "What's Next",
            systemImageName: "arrow.right.circle"
        )
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add a task to \(.applicationName)",
                "Dodaj zadatak u \(.applicationName)"
            ],
            shortTitle: "Add a Task",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: CompleteCurrentTaskIntent(),
            phrases: [
                "Complete the current task in \(.applicationName)",
                "Finish this task in \(.applicationName)",
                "Zavrsi trenutni zadatak u \(.applicationName)",
                "Završi trenutni zadatak u \(.applicationName)"
            ],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: CaptureNotesIntent(),
            phrases: [
                "Capture notes in \(.applicationName)",
                "Capture this in \(.applicationName)",
                "Zabiljezi biljeske u \(.applicationName)",
                "Zabilježi bilješke u \(.applicationName)"
            ],
            shortTitle: "Capture Notes",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: SwitchOrdoPresetIntent(),
            phrases: [
                "Switch Up next preset in \(.applicationName)",
                "Change the sort order in \(.applicationName)",
                "Change the Up next preset in \(.applicationName)",
                "Promijeni preset za Sljedeće u \(.applicationName)",
                "Promijeni preset za Sljedece u \(.applicationName)",
                "Promijeni postavku Sljedeće u \(.applicationName)"
            ],
            shortTitle: "Up Next Preset",
            systemImageName: "arrow.up.arrow.down.circle"
        )
        AppShortcut(
            intent: StartImpulsIntent(),
            phrases: [
                "Pick one in \(.applicationName)",
                "What can I do right now in \(.applicationName)",
                "Start Pick one in \(.applicationName)",
                "Odaberi jedan u \(.applicationName)",
                "Pokreni Odaberi jedan u \(.applicationName)"
            ],
            shortTitle: "Pick One",
            systemImageName: "bolt.circle"
        )
        AppShortcut(
            intent: PinFocusIntent(),
            phrases: [
                "Pin a focus task in \(.applicationName)",
                "Focus on a task in \(.applicationName)",
                "Prikaci fokus zadatak u \(.applicationName)",
                "Prikači fokus zadatak u \(.applicationName)"
            ],
            shortTitle: "Pin Focus",
            systemImageName: "pin.circle"
        )
        AppShortcut(
            intent: FindTasksIntent(),
            phrases: [
                "Find tasks in \(.applicationName)",
                "Search tasks in \(.applicationName)",
                "Pronadji zadatke u \(.applicationName)",
                "Pronađi zadatke u \(.applicationName)",
                "Trazi zadatke u \(.applicationName)",
                "Traži zadatke u \(.applicationName)"
            ],
            shortTitle: "Find Tasks",
            systemImageName: "magnifyingglass.circle"
        )
        AppShortcut(
            intent: OpenTaskIntent(),
            phrases: [
                "Open \(\.$task) in \(.applicationName)",
                "Otvori \(\.$task) u \(.applicationName)"
            ],
            shortTitle: "Open Task",
            systemImageName: "arrow.up.forward.circle"
        )
        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: [
                "Complete \(\.$task) in \(.applicationName)",
                "Zavrsi \(\.$task) u \(.applicationName)",
                "Završi \(\.$task) u \(.applicationName)"
            ],
            shortTitle: "Complete a Task",
            systemImageName: "checkmark.seal"
        )
    }
}
