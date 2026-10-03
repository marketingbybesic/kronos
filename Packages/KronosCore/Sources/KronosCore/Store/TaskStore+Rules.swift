// Part of TaskStore: the house-rule list (triage and Impuls read it).
//
// Rules are managed in their own list, never with Cmd-Z, so nothing here pushes an undo step.
// A rule is identified for dedupe by its folded text (case, accents and surrounding spaces
// ignored) plus its scope: triage on two devices learning the same rule, or an agent proposing
// one the person already has, must not leave two copies.

import Foundation
import SwiftData

extension KRule {
    /// The dedupe key: folded text plus scope.
    public var dedupeKey: String { KRule.dedupeKey(text: text, scopeRaw: scopeRaw) }

    static func dedupeKey(text: String, scopeRaw: Int) -> String {
        KTextFold.fold(String(text.prefix(160))) + "|" + String(scopeRaw)
    }
}

@MainActor
extension TaskStore {

    /// Add a rule unless an equal one (same `dedupeKey`) exists. `inserted` is false when the
    /// existing rule is returned; it is returned UNCHANGED (its active state, source and text
    /// stay as the person left them). A new rule gets `active`. NO UNDO.
    @discardableResult
    public func addRule(text: String, scope: KRuleScope, source: KRuleSource,
                        active: Bool) -> (rule: KRule, inserted: Bool) {
        insertRuleUnlessEqual(text: text, scope: scope, source: source, active: active)
    }

    /// Delete the rule with this id. False when there is none. NO UNDO.
    @discardableResult
    public func deleteRule(_ id: UUID) -> Bool { removeRule(id) }

    /// Turn the rule with this id on or off. False when there is none; true (and no write)
    /// when it already has that state. NO UNDO.
    @discardableResult
    public func setRuleActive(_ id: UUID, _ active: Bool) -> Bool { writeRuleActive(id, active) }

    // The bodies carry names of their own. The `TaskStoring` extension below forwards here; had
    // it forwarded to the public names, overload resolution could pick the extension itself
    // (its optional result type needs no conversion) and the call would recurse until the stack
    // ran out.

    func insertRuleUnlessEqual(text: String, scope: KRuleScope, source: KRuleSource,
                               active: Bool) -> (rule: KRule, inserted: Bool) {
        let key = KRule.dedupeKey(text: text, scopeRaw: scope.rawValue)
        let all = (try? context.fetch(FetchDescriptor<KRule>())) ?? []
        if let existing = all.filter({ $0.dedupeKey == key }).min(by: RuleOrder.older) {
            return (existing, false)
        }
        let r = KRule(text: text, scope: scope, source: source)
        r.isActive = active
        context.insert(r)
        saveContext()
        return (r, true)
    }

    func removeRule(_ id: UUID) -> Bool {
        let d = FetchDescriptor<KRule>(predicate: #Predicate { $0.id == id })
        let rows = (try? context.fetch(d)) ?? []
        guard !rows.isEmpty else { return false }
        for r in rows { context.delete(r) }
        saveContext()
        return true
    }

    func writeRuleActive(_ id: UUID, _ active: Bool) -> Bool {
        let d = FetchDescriptor<KRule>(predicate: #Predicate { $0.id == id })
        guard let r = (try? context.fetch(d))?.first else { return false }
        guard r.isActive != active else { return true }
        r.isActive = active
        r.updatedAt = Date()
        saveContext()
        return true
    }
}

/// The same rule operations for any `TaskStoring` (the MCP dispatcher holds the protocol type).
/// Only `TaskStore` stores rules; any other conformer reports "not found".
public extension TaskStoring {
    @discardableResult
    func deleteRule(_ id: UUID) -> Bool {
        (self as? TaskStore)?.removeRule(id) ?? false
    }

    @discardableResult
    func setRuleActive(_ id: UUID, _ active: Bool) -> Bool {
        (self as? TaskStore)?.writeRuleActive(id, active) ?? false
    }

    /// See `TaskStore.addRule(text:scope:source:active:)`. Nil for a store without rules.
    @discardableResult
    func addRule(text: String, scope: KRuleScope, source: KRuleSource,
                 active: Bool) -> (rule: KRule, inserted: Bool)? {
        (self as? TaskStore)?.insertRuleUnlessEqual(text: text, scope: scope, source: source, active: active)
    }
}

enum RuleOrder {
    /// Older first: createdAt, then id (the same on every device).
    static func older(_ a: KRule, _ b: KRule) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}
