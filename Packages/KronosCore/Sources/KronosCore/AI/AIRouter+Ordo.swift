// "Tell Up next ...": reorder the visible queue from one sentence, as a PREVIEW. Nothing here
// touches a store: the caller shows the ids in the order returned, and applies them (as one undo
// step) only when the person confirms.

import Foundation

/// One task of the queue that is offered for reordering.
public struct OrdoCandidate: Sendable, Equatable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

/// What a reorder request would do.
public struct OrdoResortPreview: Sendable, Equatable {
    /// Every candidate id exactly once, in the proposed order. The input order when the model
    /// answered nothing usable.
    public let ids: [UUID]
    /// One short line saying what moved and why (or that nothing did).
    public let explanation: String
    /// False when `ids` equals the input order.
    public let changed: Bool

    public init(ids: [UUID], explanation: String, changed: Bool) {
        self.ids = ids
        self.explanation = explanation
        self.changed = changed
    }
}

extension AIRouter {

    /// The most queue entries sent to the model at once; later ones keep their place after them.
    static let ordoResortLimit = 30

    /// Preview of a reorder. Never throws and never writes: a refusal, an invalid permutation, an
    /// empty instruction, AI off or a failed call all return the input order unchanged.
    public func resortOrdoPreview(instruction: String, candidates: [OrdoCandidate],
                                  language: String = "en") async -> OrdoResortPreview {
        let original = candidates.map(\.id)
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, candidates.count > 1, mode != .off else {
            return OrdoResortPreview(ids: original, explanation: OrdoResort.notAnInstruction, changed: false)
        }
        let head = Array(candidates.prefix(Self.ordoResortLimit))
        let tail = Array(candidates.dropFirst(Self.ordoResortLimit))
        let titles = EgressLimits.cappedTitles(head.map(\.title), limit: head.count)
        let reply: OrdoResort
        do {
            reply = try await ordoResort(queueTitles: titles, message: PrivacyRedactor.redact(trimmed),
                                         history: [], language: language)
        } catch {
            return OrdoResortPreview(ids: original, explanation: OrdoResort.notAnInstruction, changed: false)
        }
        guard !reply.isNoOp, reply.isValid(queueCount: head.count) else {
            return OrdoResortPreview(ids: original, explanation: reply.explanation, changed: false)
        }
        let ids = reply.order.map { head[$0 - 1].id } + tail.map(\.id)
        return OrdoResortPreview(ids: ids, explanation: reply.explanation, changed: ids != original)
    }

    /// The proposed order of `candidates` for `instruction`, as ids. Preview only (see above).
    public func resortOrdo(instruction: String, candidates: [OrdoCandidate],
                           language: String = "en") async -> [UUID] {
        await resortOrdoPreview(instruction: instruction, candidates: candidates, language: language).ids
    }
}
