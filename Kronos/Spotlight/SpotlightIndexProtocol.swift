// Kronos/Spotlight/SpotlightIndexProtocol.swift
//
// The injected seam: `SpotlightIndexer` never talks to `CSSearchableIndex.default()`
// directly, only through this protocol, so a fixture can stand in during snapshot runs and
// the verify script's fixture executable. `real` wraps the actual system index; hermetic
// callers use `FixtureSearchIndex` and never construct `real` at all.

import Foundation
import CoreSpotlight

/// Write surface `SpotlightIndexer` needs from a search index. Mirrors the two
/// `CSSearchableIndex` calls it makes; nothing else is exposed so a fixture stays trivial.
protocol SearchIndexing: Sendable {
    func indexItems(_ items: [SearchableFacts]) async throws
    func deleteItems(withIdentifiers ids: [String]) async throws
}

/// The real system index. Only ever constructed when NOT running under `KRONOS_SNAPSHOT`
/// (SpotlightIndexer.swift enforces this — this type does not check the env var itself, so
/// it stays a plain, honest wrapper with no hidden hermetic branch of its own).
struct RealSearchIndex: SearchIndexing {
    init() {}

    func indexItems(_ items: [SearchableFacts]) async throws {
        guard !items.isEmpty else { return }
        let searchable = items.map { $0.asSearchableItem() }
        try await CSSearchableIndex.default().indexSearchableItems(searchable)
    }

    func deleteItems(withIdentifiers ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids)
    }
}

/// In-memory stand-in for tests and snapshot runs. Records every call so a test can assert
/// on exactly which ids were added or removed, in order.
actor FixtureSearchIndex: SearchIndexing {
    private(set) var indexedIDs: [String] = []
    private(set) var deletedIDs: [String] = []

    init() {}

    func indexItems(_ items: [SearchableFacts]) async throws {
        indexedIDs.append(contentsOf: items.map(\.id))
    }

    func deleteItems(withIdentifiers ids: [String]) async throws {
        deletedIDs.append(contentsOf: ids)
    }

    /// Current membership: everything indexed minus everything since deleted, most-recent
    /// operation per id wins (a later delete removes an earlier index and vice versa).
    func currentIDs() -> Set<String> {
        var ids = Set(indexedIDs)
        ids.subtract(deletedIDs)
        return ids
    }
}

private extension SearchableFacts {
    func asSearchableItem() -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = title
        attrs.contentDescription = [firstMove, subtitle, deadlineText]
            .compactMap { $0 }.joined(separator: " · ")
        let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domainIdentifier,
                                    attributeSet: attrs)
        item.expirationDate = .distantFuture
        return item
    }
}
