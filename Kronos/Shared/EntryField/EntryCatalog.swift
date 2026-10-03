// Kronos/Shared/EntryField/EntryCatalog.swift
// What the entry field resolves `#` and `@` against, read from the store: names for Core's
// matcher (`EntryDirectory`) plus the glyph (icon + colour) of each project and area for the
// pills and the suggestion rows. A snapshot of the store at one moment: rebuilt when
// `AppModel.version` changes, never read per keystroke.
import Foundation
import KronosCore

struct EntryCatalog {
    struct Glyph: Equatable {
        var icon: String?
        var colorHex: String?
    }

    var directory: EntryDirectory
    var glyphs: [UUID: Glyph]

    static let empty = EntryCatalog(directory: EntryDirectory(), glyphs: [:])

    func glyph(for destination: EntryDestination) -> Glyph? {
        destination.id.flatMap { glyphs[$0] }
    }

    @MainActor
    static func make(store: TaskStore, recents: EntryRecents = EntryRecents()) -> EntryCatalog {
        var glyphs: [UUID: Glyph] = [:]
        let projects = store.allProjects().map { p -> EntryName in
            glyphs[p.id] = Glyph(icon: p.icon, colorHex: p.colorHex)
            return EntryName(p.name, id: p.id, lastUsed: recents.lastUsed(.project(p.id)))
        }
        let areas = store.allAreas().map { a -> EntryName in
            glyphs[a.id] = Glyph(icon: nil, colorHex: a.colorHex)
            return EntryName(a.name, id: a.id, lastUsed: recents.lastUsed(.area(a.id)))
        }
        let labels = store.labels().map { EntryName($0.name, id: $0.id, lastUsed: recents.lastUsed(.label($0.name))) }
        return EntryCatalog(directory: EntryDirectory(projects: projects, areas: areas, labels: labels), glyphs: glyphs)
    }
}

/// When the user last filed something into a project, area or label through an entry field.
/// Only ever breaks ties between equally good matches (Core `EntryName.lastUsed`).
struct EntryRecents {
    enum Key {
        case project(UUID), area(UUID), label(String)

        var raw: String {
            switch self {
            case .project(let id): return "project:" + id.uuidString
            case .area(let id): return "area:" + id.uuidString
            case .label(let name): return "label:" + KTextFold.fold(name)
            }
        }
    }

    static let defaultsKey = "kronos.entry.recents.v1"
    /// A test or snapshot run keeps its own store so it never writes into the person's recents.
    private static var hermetic: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["KRONOS_SNAPSHOT"] != nil || env["KRONOS_UITEST"] != nil
    }

    var defaults: UserDefaults = Self.hermetic ? (UserDefaults(suiteName: "kronos.hermetic.entry") ?? .standard) : .standard
    /// Entries older than this are forgotten, so the file does not grow forever.
    var keep = 200

    private var table: [String: Double] { defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:] }

    func lastUsed(_ key: Key) -> Date? {
        table[key.raw].map { Date(timeIntervalSince1970: $0) }
    }

    func record(_ keys: [Key], now: Date = Date()) {
        guard !keys.isEmpty else { return }
        var t = table
        for k in keys { t[k.raw] = now.timeIntervalSince1970 }
        if t.count > keep {
            for old in t.sorted(by: { $0.value < $1.value }).prefix(t.count - keep) { t[old.key] = nil }
        }
        defaults.set(t, forKey: Self.defaultsKey)
    }
}
