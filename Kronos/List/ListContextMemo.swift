// Kronos/List/ListContextMemo.swift
// A one-entry memo: the value built for the last key, rebuilt only when the key changes. The
// list screen reads its rows many times per render (body, keys, the "next" publisher, the
// completion hand-off, the menu bar, the Dock menu); with this they all share ONE build per
// state of the list instead of filtering and sorting every task again on each read.
// Foundation only, so scripts/bulk-selftest.swift compiles THIS file against hand-written cases.
import Foundation

struct ListContextMemo<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?
    /// How many times `build` ran (the scale gate reads it: one build per mutation).
    private(set) var builds = 0

    /// The value for `key`: the stored one when the key is equal to the last, else `build()`.
    mutating func value(for key: Key, build: () -> Value) -> Value {
        if let stored = value, self.key == key { return stored }
        let fresh = build()
        builds += 1
        self.key = key
        value = fresh
        return fresh
    }

    /// Forget the stored value (the next read builds again).
    mutating func reset() {
        key = nil
        value = nil
    }
}
