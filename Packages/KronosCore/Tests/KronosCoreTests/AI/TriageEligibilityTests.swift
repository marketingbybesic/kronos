import Testing
@testable import KronosCore

struct TriageEligibilityTests {

    // (automatic, needsTriage, expected mayRun)
    @Test(arguments: [
        (true, true, true),     // person created it, triage pending: runs
        (true, false, false),   // agent create with triage:false: untouched
        (false, false, true),   // deliberate Re-triage: always allowed
        (false, true, true),
    ])
    func mayRunTable(automatic: Bool, needsTriage: Bool, expected: Bool) {
        #expect(TriageEligibility.mayRun(automatic: automatic, needsTriage: needsTriage) == expected)
    }

    // (automatic, source, expected fillsWithoutUndo)
    @Test(arguments: [
        (true, Optional("mcp"), true),
        (true, Optional("agent"), true),
        (true, Optional<String>.none, false),   // the person's own task keeps its undoable fill
        (true, Optional(""), false),
        (false, Optional("mcp"), false),        // a deliberate Re-triage stays undoable
    ])
    func noUndoTable(automatic: Bool, source: String?, expected: Bool) {
        #expect(TriageEligibility.fillsWithoutUndo(automatic: automatic, source: source) == expected)
    }
}
