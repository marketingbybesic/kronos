// When the creation-time auto-triage may touch a task, and how its writes are recorded.
// Pure values only, so the rules are unit-testable outside the app target that applies them.

import Foundation

public enum TriageEligibility {

    /// A run started by a task's creation only touches a task that still asks for triage.
    /// MCP, agent and capture creations that say `triage: false` (the MCP default) clear
    /// `needsTriage` right after the row exists, and are left exactly as written; `triage: true`
    /// keeps it set. A deliberate Re-triage (`automatic == false`) is the person's own action and
    /// is always allowed.
    public static func mayRun(automatic: Bool, needsTriage: Bool) -> Bool {
        !automatic || needsTriage
    }

    /// A task that carries a machine `source` (MCP, agent, capture, import) is filled without an
    /// undo step, so a machine write can never bury the person's own last action. Only creation
    /// time runs qualify: a deliberate Re-triage stays undoable.
    public static func fillsWithoutUndo(automatic: Bool, source: String?) -> Bool {
        guard automatic, let source else { return false }
        return !source.isEmpty
    }
}
