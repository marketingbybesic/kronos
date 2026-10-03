// Kronos/MenuBar/MenuBarOrdoCommand.swift
// "Tell Ordo...": the deterministic part of a one-line reorder instruction typed in the
// popover, so the common commands never need an AI call. Foundation only; hand-tabled by
// scripts/menubar-hit-selftest.swift against this exact file.
//
// Grammar (case and diacritics ignored), English and Croatian:
//   "<x> first" / "put <x> first" / "<x> to the top" / "<x> prvo" / "<x> na vrh"
//   "<x> last"  / "<x> to the end" / "<x> zadnje"    / "<x> na kraj"
// A queue item matches <x> when its title or its project name contains <x>. Matching items
// keep their relative order and move to the front (or the back); the rest keep theirs too.
import Foundation

struct OrdoQueueItem: Equatable {
    let title: String
    let project: String?
}

struct OrdoCommandResult: Equatable {
    /// New order as 1-based positions of the queue that was given: an exact permutation.
    let order: [Int]
    /// How many items matched <x> and moved.
    let matched: Int
    let toFront: Bool
    let needle: String
}

enum OrdoCommandGrammar {
    private static let frontSuffixes = [" to the top", " to the front", " na vrh", " prvo", " prvi", " first"]
    private static let backSuffixes = [" to the end", " to the bottom", " na kraj", " zadnje", " zadnji", " last"]
    private static let prefixes = ["put ", "move ", "stavi ", "pomakni "]

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil: not a command this grammar knows, or nothing in the queue matches (the caller may
    /// then ask the AI router, or say so).
    static func parse(_ message: String, queue: [OrdoQueueItem]) -> OrdoCommandResult? {
        var text = fold(message)
        guard !text.isEmpty, !queue.isEmpty else { return nil }
        var toFront: Bool?
        for suffix in frontSuffixes where text.hasSuffix(suffix) {
            toFront = true; text = String(text.dropLast(suffix.count)); break
        }
        if toFront == nil {
            for suffix in backSuffixes where text.hasSuffix(suffix) {
                toFront = false; text = String(text.dropLast(suffix.count)); break
            }
        }
        guard let toFront else { return nil }
        for prefix in prefixes where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let hit = queue.map { item in
            fold(item.title).contains(needle) || (item.project.map { fold($0).contains(needle) } ?? false)
        }
        let matchedPositions = hit.indices.filter { hit[$0] }.map { $0 + 1 }
        let restPositions = hit.indices.filter { !hit[$0] }.map { $0 + 1 }
        guard !matchedPositions.isEmpty else { return nil }
        let order = toFront ? matchedPositions + restPositions : restPositions + matchedPositions
        return OrdoCommandResult(order: order, matched: matchedPositions.count, toFront: toFront, needle: needle)
    }

    /// True when `order` is an exact permutation of 1...count (the router's own rule, repeated
    /// here so an AI reply is checked before it can touch anything).
    static func isPermutation(_ order: [Int], count: Int) -> Bool {
        count > 0 && order.count == count && Set(order) == Set(1...count)
    }

    /// True when applying `order` would change nothing.
    static func isIdentity(_ order: [Int]) -> Bool {
        order.enumerated().allSatisfy { $0.element == $0.offset + 1 }
    }
}
