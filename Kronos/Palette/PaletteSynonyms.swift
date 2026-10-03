// Kronos/Palette/PaletteSynonyms.swift
// Words a person may still type for a command that was renamed, or that other tools call
// something else. They are matched next to the visible title and never shown. Keys are
// registry command ids; every id must exist in PaletteCommands (the self-test checks it).
import Foundation

enum PaletteSynonyms {
    /// Command id -> extra search words (matched folded, so "trijaža" and "trijaza" are one).
    static let table: [String: [String]] = [
        "session.impuls": ["impuls", "pick one", "odaberi jedan"],
        "session.upnext": ["ordo", "up next", "sljedece", "sljedeće"],
        "session.triage": ["triage", "trijaža", "trijaza", "razvrstavanje", "razvrstaj", "sort"],
        "task.retriage": ["triage", "trijaža", "trijaza", "razvrstaj"],
        "coach.retriage": ["triage", "trijaža", "trijaza", "razvrstaj"],
        "session.sweep": ["sweep", "pregled", "počisti", "pocisti"],
        "task.pickdate": ["date", "datum", "due", "rok", "deadline"],
        "task.deadline.today": ["due", "date", "datum", "rok", "deadline"],
        "task.deadline.tomorrow": ["due", "date", "datum", "rok", "deadline"],
        "task.deadline.nextweek": ["due", "date", "datum", "rok", "deadline"],
        "task.deadline.none": ["due", "date", "datum", "rok", "deadline", "no date", "bez roka"],
        "task.moveto": ["project", "projekt", "move", "premjesti"],
        "task.waiting": ["waiting", "ceka", "čeka", "blocked"],
        "task.someday": ["someday", "jednom", "maybe"],
        "task.rename": ["title", "naslov", "preimenuj"],
        "task.duplicate": ["copy", "clone", "kopija", "dupliciraj"],
        "task.copylink": ["link", "url", "poveznica"],
        "session.morningplan": ["morning", "plan", "jutro", "jutarnji", "today"],
    ]

    static func aliases(for id: String) -> [String] { table[id] ?? [] }
}
