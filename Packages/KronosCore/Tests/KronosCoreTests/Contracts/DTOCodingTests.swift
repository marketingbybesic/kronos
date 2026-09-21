import Testing
import Foundation
@testable import KronosCore

/// Strict decoding: the reference DTO samples decode, and
/// a sample missing a schema-required field THROWS rather than defaulting.
/// That distinction is the whole point — a model that drops `firstMove` must
/// be a hop to the next candidate, not a task with an empty first move.
struct DTOCodingTests {

    private let decoder = JSONDecoder()
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - TriageResult

    /// The HR reference output, verbatim.
    private let triageHR = #"""
    {"project":"Acme","priority":3,"due":"2026-09-17","depth":"shallow","estimateMinutes":10,
     "energyKind":"people","firstMove":"Otvoriti imenik i pronaći Alexov broj.",
     "labels":[],"rationale":"Kratak poziv, bez pripreme, zato je plitko i deset minuta."}
    """#

    @Test func triageReferenceSampleDecodes() throws {
        let r = try decode(TriageResult.self, triageHR)
        #expect(r.project == "Acme")
        #expect(r.priority == 3)
        #expect(r.due == "2026-09-17")
        #expect(r.depth == .shallow)
        #expect(r.depth.kDepth == .shallow)
        #expect(r.estimateMinutes == 10)
        #expect(r.energyKind == .people)
        #expect(r.energyKind.kEnergyKind == .people)
        #expect(r.firstMove == "Otvoriti imenik i pronaći Alexov broj.")
        #expect(r.labels.isEmpty)
        #expect(r.proposedRule == nil)
        #expect(!r.isDeterministic)
    }

    @Test func triageAcceptsExplicitNullsForNullableFields() throws {
        // The EN reference output: project and due are explicit nulls.
        let r = try decode(TriageResult.self, #"""
        {"project":null,"priority":2,"due":null,"depth":"shallow","estimateMinutes":15,
         "energyKind":"admin","firstMove":"Open the invoice folder and find September.",
         "labels":[],"rationale":"One document and one email, no preparation needed."}
        """#)
        #expect(r.project == nil)
        #expect(r.due == nil)
        #expect(r.energyKind == .admin)
    }

    @Test func triageMissingRequiredFieldThrows() {
        // `firstMove` removed: required by the schema, so this must NOT
        // decode into a TriageResult with an empty first move.
        let missing = #"""
        {"project":"Acme","priority":3,"due":null,"depth":"shallow","estimateMinutes":10,
         "energyKind":"people","labels":[],"rationale":"Kratak poziv."}
        """#
        #expect(throws: (any Error).self) {
            _ = try decode(TriageResult.self, missing)
        }
    }

    @Test func triageMissingRationaleThrows() {
        let missing = #"""
        {"priority":1,"depth":"deep","estimateMinutes":60,"energyKind":"deepWork",
         "firstMove":"Open the draft.","labels":[]}
        """#
        #expect(throws: (any Error).self) {
            _ = try decode(TriageResult.self, missing)
        }
    }

    @Test func triageRejectsAnUnknownDepthSpelling() {
        // The prompt schema permits only shallow|deep. `unknown` is a local
        // state for untriaged rows, never something a model may return.
        #expect(throws: (any Error).self) {
            _ = try decode(TriageResult.self, #"""
            {"priority":1,"depth":"unknown","estimateMinutes":60,"energyKind":"admin",
             "firstMove":"Open it.","labels":[],"rationale":"x"}
            """#)
        }
    }

    @Test func deterministicTriageIsVersionZeroSoTheQueueComesBack() {
        let r = TriageResult.deterministic(firstMove: "Open the folder.")
        #expect(r.version == 0)
        #expect(r.isDeterministic)
        #expect(r.rationale.isEmpty)
    }

    // MARK: - ProposedRule

    @Test func retriageDecodesTheBareStringProposedRule() throws {
        let r = try decode(TriageResult.self, #"""
        {"project":"Globex","priority":2,"due":null,"depth":"shallow","estimateMinutes":20,
         "energyKind":"admin","firstMove":"Otvoriti wp-admin i naći popis korisnika.",
         "labels":[],"rationale":"Administracija koju radi rutinski.",
         "proposedRule":"Globex administrativni zadaci su plitki."}
        """#)
        let rule = try #require(r.proposedRule)
        #expect(rule.text == "Globex administrativni zadaci su plitki.")
        #expect(rule.scope == .all)
        #expect(rule.isMeaningful)
    }

    @Test func proposedRuleRoundTripsAsABareString() throws {
        let rule = ProposedRule(text: "Globex admin tasks are shallow.")
        let data = try JSONEncoder().encode(rule)
        #expect(String(data: data, encoding: .utf8) == "\"Globex admin tasks are shallow.\"")
        #expect(try decoder.decode(ProposedRule.self, from: data) == rule)
    }

    @Test func proposedRuleNoOpGuardRejectsASingleTaskRestatement() {
        #expect(!ProposedRule(text: "This task is shallow.").isMeaningful)
        #expect(!ProposedRule(text: "short").isMeaningful)
        #expect(ProposedRule(text: "Globex admin tasks are shallow.").isMeaningful)
    }

    @Test func proposedRuleTruncatesAtTheSchemaLimit() {
        let long = String(repeating: "a", count: 300)
        #expect(ProposedRule(text: long).text.count == 140)
    }

    // MARK: - ImpulsRanking

    @Test func impulsReferenceSampleDecodesAndValidates() throws {
        let r = try decode(ImpulsRanking.self, #"""
        {"ranked":[
         {"position":3,"mentorLine":"Ovo ima rok danas, zato je prvo."},
         {"position":1,"mentorLine":"Jedan poziv od deset minuta."},
         {"position":5,"mentorLine":"Kratko, staje prije sljedećeg termina."}]}
        """#)
        #expect(r.ranked.count == 3)
        #expect(r.ranked[0].position == 3)
        #expect(r.isValid(candidateCount: 5))
    }

    @Test func impulsMissingMentorLineThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(ImpulsRanking.self, #"{"ranked":[{"position":1}]}"#)
        }
    }

    @Test func impulsRejectsRepeatedOrOutOfRangePositions() throws {
        let dup = try decode(ImpulsRanking.self, #"""
        {"ranked":[{"position":2,"mentorLine":"a"},{"position":2,"mentorLine":"b"}]}
        """#)
        #expect(!dup.isValid(candidateCount: 5))

        let over = try decode(ImpulsRanking.self, #"""
        {"ranked":[{"position":9,"mentorLine":"a"}]}
        """#)
        #expect(!over.isValid(candidateCount: 5))
        #expect(!ImpulsRanking(ranked: []).isValid(candidateCount: 5))
    }

    // MARK: - OrdoResort

    @Test func ordoResortReferenceSampleDecodes() throws {
        let r = try decode(OrdoResort.self, #"""
        {"order":[2,3,4,1],"explanation":"Globex je pomaknut na kraj, ostali zadržavaju redoslijed.","proposedRule":null}
        """#)
        #expect(r.order == [2, 3, 4, 1])
        #expect(r.proposedRule == nil)
        #expect(r.isValid(queueCount: 4))
        #expect(!r.isNoOp)
    }

    @Test func ordoResortOrderMustBeAnExactPermutation() throws {
        // Dropped position 3: applying this would silently lose a task, so
        // the reply is rejected whole and the queue is left untouched.
        let dropped = try decode(OrdoResort.self, #"{"order":[1,2,4],"explanation":"x"}"#)
        #expect(!dropped.isValid(queueCount: 4))

        let duplicated = try decode(OrdoResort.self, #"{"order":[1,1,3,4],"explanation":"x"}"#)
        #expect(!duplicated.isValid(queueCount: 4))

        let invented = try decode(OrdoResort.self, #"{"order":[1,2,3,9],"explanation":"x"}"#)
        #expect(!invented.isValid(queueCount: 4))
    }

    @Test func ordoResortMissingOrderThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode(OrdoResort.self, #"{"explanation":"Not a queue instruction"}"#)
        }
    }

    @Test func ordoResortHandlesTheEmptyQueueWithoutTrapping() throws {
        // `1...0` is an invalid range that traps at runtime, so the empty
        // queue must be rejected before the range is ever formed.
        let r = try decode(OrdoResort.self, #"{"order":[],"explanation":"x"}"#)
        #expect(!r.isValid(queueCount: 0))
        #expect(!r.isValid(queueCount: 3))
        #expect(OrdoResort.unchanged(queueCount: 0).order.isEmpty)
    }

    @Test func ordoResortRecognisesTheNonInstructionSentinel() throws {
        let r = try decode(OrdoResort.self, #"""
        {"order":[1,2,3,4],"explanation":"Not a queue instruction","proposedRule":null}
        """#)
        #expect(r.isNoOp)
        #expect(r.isValid(queueCount: 4))
        #expect(OrdoResort.unchanged(queueCount: 3).order == [1, 2, 3])
        #expect(OrdoResort.unchanged(queueCount: 3).isNoOp)
    }
}
