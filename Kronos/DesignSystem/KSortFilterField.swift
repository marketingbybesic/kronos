// Kronos/DesignSystem/KSortFilterField.swift
// Generic field description consumed by KSortBuilder/KFilterBuilder, so the design
// system never imports KronosCore's own field/enum types. A screen adapts its real
// domain type (Status, Priority, Project, …) to this shape at the call site.
import SwiftUI

public struct KSortFilterField: Identifiable, Hashable {
    public let id: AnyHashable
    public let name: String
    public let symbol: String   // SF Symbol / Icon name

    public init<ID: Hashable>(id: ID, name: String, symbol: String) {
        self.id = AnyHashable(id)
        self.name = name
        self.symbol = symbol
    }

    public static func == (a: KSortFilterField, b: KSortFilterField) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
