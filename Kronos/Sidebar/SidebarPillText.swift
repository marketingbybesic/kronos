// Kronos/Sidebar/SidebarPillText.swift
// The sentences of the undo pill the sidebar raises. Every pattern is a literal catalog key; the
// number picks one of three Croatian forms (KPluralCategory) before it is formatted.
import Foundation

enum SidebarPillText {
    /// "Archived <name>" plus how many open tasks that hides, when any.
    static func archived(name: String, hiddenOpenTasks n: Int) -> String {
        guard n > 0 else { return String(format: String(localized: "sidebar.archive.pill.none"), name) }
        let pattern: String
        switch KPluralCategory.category(for: n, isCroatian: KronosLocale.languageCode == "hr") {
        case .one: pattern = String(localized: "sidebar.archive.pill.one")
        case .few: pattern = String(localized: "sidebar.archive.pill.few")
        case .many: pattern = String(localized: "sidebar.archive.pill.many")
        }
        return String(format: pattern, name, n)
    }

    static func areaDeleted(name: String) -> String {
        String(format: String(localized: "sidebar.area.deleted.pill"), name)
    }

    static func moved(toProject name: String) -> String {
        String(format: String(localized: "sidebar.drop.moved.pill"), name)
    }
}
