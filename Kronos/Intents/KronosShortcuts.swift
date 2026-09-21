// Kronos/Intents/KronosShortcuts.swift. Natural-language phrases for Siri and Shortcuts, EN +
// HR, each containing `\(.applicationName)` (Apple requires it so Siri can disambiguate which
// app answers). AppShortcutsProvider is discovered automatically by the system at launch —
// nothing else needs to register it.

import AppIntents

struct KronosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsNextIntent(),
            phrases: [
                "What's next in \(.applicationName)",
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
                "Switch Ordo preset in \(.applicationName)",
                "Change the sort order in \(.applicationName)",
                "Promijeni Ordo preset u \(.applicationName)"
            ],
            shortTitle: "Switch Ordo Preset",
            systemImageName: "arrow.up.arrow.down.circle"
        )
        AppShortcut(
            intent: StartImpulsIntent(),
            phrases: [
                "Start Impuls in \(.applicationName)",
                "What can I do right now in \(.applicationName)",
                "Pokreni Impuls u \(.applicationName)"
            ],
            shortTitle: "Start Impuls",
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
    }
}
