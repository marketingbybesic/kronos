// Ticket.swift — what extensions and the Watch write; the app applies each exactly once.
// Idempotent by id: the ledger remembers applied ids for 30 days.

import Foundation

public enum TicketKind: String, Codable, Sendable, CaseIterable {
    case complete, undoComplete, snooze, create, addSubtask, attach, startSession, endSession, pin
}

public struct Ticket: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: TicketKind
    public var payload: [String: String]
    public var createdAt: Date
    public var device: String

    public init(id: UUID = UUID(), kind: TicketKind, payload: [String: String] = [:], createdAt: Date = Date(), device: String) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.device = device
    }
}

/// `Tickets/<uuid>.json` files plus `TicketLedger.json`. The app process is the only applier.
public final class TicketInbox: @unchecked Sendable {
    public static let ledgerFileName = "TicketLedger.json"
    public static let ledgerRetention: TimeInterval = 30 * 24 * 3600

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    var ticketsDirectory: URL { directory.appendingPathComponent("Tickets", isDirectory: true) }
    var ledgerURL: URL { directory.appendingPathComponent(Self.ledgerFileName) }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Extension side: one file per ticket, atomic.
    public func submit(_ ticket: Ticket) throws {
        try FileManager.default.createDirectory(at: ticketsDirectory, withIntermediateDirectories: true)
        let url = ticketsDirectory.appendingPathComponent("\(ticket.id.uuidString).json")
        try encoder().encode(ticket).write(to: url, options: .atomic)
    }

    /// Pending tickets, oldest first. Unreadable files are skipped, not deleted.
    public func pending() -> [Ticket] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: ticketsDirectory, includingPropertiesForKeys: nil)) ?? []
        let d = decoder()
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? d.decode(Ticket.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// App side. Runs `handler` at most once per ticket id, ever (within the retention window):
    /// the id is recorded before the file is deleted, so a crash between the two re-delivers the
    /// file but never applies it twice. Returns true when the handler ran.
    @discardableResult
    public func apply(_ ticket: Ticket, now: Date = Date(), handler: (Ticket) throws -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var ledger = loadLedger(now: now)
        let file = ticketsDirectory.appendingPathComponent("\(ticket.id.uuidString).json")
        if ledger[ticket.id.uuidString] != nil {
            try? FileManager.default.removeItem(at: file)
            return false
        }
        try handler(ticket)
        ledger[ticket.id.uuidString] = now
        try saveLedger(ledger)
        try? FileManager.default.removeItem(at: file)
        return true
    }

    public func hasApplied(_ id: UUID, now: Date = Date()) -> Bool {
        loadLedger(now: now)[id.uuidString] != nil
    }

    private func loadLedger(now: Date) -> [String: Date] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let all = try? decoder().decode([String: Date].self, from: data) else { return [:] }
        return all.filter { now.timeIntervalSince($0.value) <= Self.ledgerRetention }
    }

    private func saveLedger(_ ledger: [String: Date]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder().encode(ledger).write(to: ledgerURL, options: .atomic)
    }
}
