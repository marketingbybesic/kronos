// Kronos/DesignSystem/ProjectIconSet.swift
// The curated project icons a user picks from: 10 groups x 8 = 80 minimalist glyphs,
// every name a key of Icon.swift's map. Eight per group so the picker grid (8 columns)
// has no ragged rows. Group titles are catalog keys; `unresolved` is the runtime proof
// that no icon falls back to the question-mark glyph on this machine (the gallery's
// `identity` section prints it and the gallery-shot binary exits non-zero on any miss).
import SwiftUI
import Foundation

public enum ProjectIconSet {
    public struct Group: Identifiable {
        public let id: String            // stable group id, also the search keyword
        public let titleKey: String      // catalog key (lowercase dotted)
        public let titleDefault: String  // English until the key lands in the catalog
        public let icons: [String]

        public var title: String {
            Bundle.main.localizedString(forKey: titleKey, value: titleDefault, table: nil)
        }
    }

    public static let groups: [Group] = [
        Group(id: "work", titleKey: "iconset.group.work", titleDefault: "Work",
              icons: ["briefcase", "building", "landmark", "folder", "target", "rocket", "clipboard", "chart-pie"]),
        Group(id: "money", titleKey: "iconset.group.money", titleDefault: "Money",
              icons: ["wallet", "euro", "credit-card", "banknote", "receipt", "trending-up", "shopping-cart", "scale"]),
        Group(id: "people", titleKey: "iconset.group.people", titleDefault: "People",
              icons: ["users", "user", "heart", "message-square", "phone", "mail", "megaphone", "graduation-cap"]),
        Group(id: "food", titleKey: "iconset.group.food", titleDefault: "Food",
              icons: ["utensils", "coffee", "wine", "carrot", "fish", "leaf", "cake", "flame"]),
        Group(id: "media", titleKey: "iconset.group.media", titleDefault: "Media",
              icons: ["camera", "video", "music", "palette", "image", "film", "mic", "pen-tool"]),
        Group(id: "web", titleKey: "iconset.group.web", titleDefault: "Web",
              icons: ["globe", "link", "code", "terminal", "server", "database", "cloud", "monitor"]),
        Group(id: "home", titleKey: "iconset.group.home", titleDefault: "Home",
              icons: ["home", "sofa", "bed", "key", "lamp", "hammer", "wrench", "paw"]),
        Group(id: "health", titleKey: "iconset.group.health", titleDefault: "Health",
              icons: ["stethoscope", "tooth", "pill", "dumbbell", "first-aid", "brain", "activity", "run"]),
        Group(id: "travel", titleKey: "iconset.group.travel", titleDefault: "Travel",
              icons: ["car", "plane", "train", "bike", "ship", "map", "suitcase", "mountain"]),
        Group(id: "misc", titleKey: "iconset.group.misc", titleDefault: "Other",
              icons: ["star", "flag", "bookmark", "zap", "lightbulb", "sparkles", "gift", "puzzle"]),
    ]

    public static var all: [String] { groups.flatMap(\.icons) }

    public static func contains(_ name: String) -> Bool { all.contains(name) }

    /// Icons of the set that would render the fallback glyph here. Must be empty.
    @MainActor public static var unresolved: [String] { Icon.unresolved(all) }

    /// Icons matching a search: by icon name or by group id / localized group title.
    public static func matching(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return groups.flatMap { group in
            let groupHit = group.id.contains(q) || group.title.lowercased().contains(q)
            return group.icons.filter { groupHit || $0.contains(q) }
        }
    }
}
