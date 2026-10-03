// The deterministic half of "break a task into subtasks". PURE: no network,
// no store access. Step 1 reuses `DeterministicFirstMove.generate` — the
// same first-move template triage already falls back to — so a task's first
// subtask is always identical to its first move. Steps 2+ are a fixed,
// generic finish-the-task sequence (open/verify/finish/deliver), verb-family
// aware where `FirstMoveLint`'s allowlists make that possible (no closing
// "check / mark finished" steps: those are filler), and every
// step is checked against `FirstMoveLint` before being returned: a step this
// generator produces that fails its own lint is a bug here, not an
// acceptable deterministic result.

import Foundation

public enum DeterministicBreakdown {

    /// Between 3 and 7 concrete steps for `title`; `firstMove` is a
    /// restatement of step 1, matching the contract the AI path also follows.
    public static func steps(title: String, notes: String, language: Lang) -> BreakdownResult {
        let step1 = DeterministicFirstMove.generate(title: title, firstMoveURL: nil,
                                                    hasOpenSubtask: false,
                                                    notesNonEmpty: !notes.isEmpty,
                                                    dread: false, language: language)
        var built = [step1]
        built.append(contentsOf: genericSteps(title: title, notesNonEmpty: !notes.isEmpty, language: language))

        // Every step must pass its own lint by construction; a template that
        // fails is a bug in this generator, so drop it rather than ship a
        // step that violates the very rules AI-produced steps are held to.
        let checked = built.filter { FirstMoveLint.lint($0, language: language, dreadMode: false).isPass }
        let final = Array(checked.prefix(7))
        return BreakdownResult(subtasks: final, firstMove: step1, isDeterministic: true)
    }

    /// A generic, verb-safe continuation after the first move: read what is
    /// there, list what is missing, start on the first item. Every step is a
    /// physical action that moves the work forward. Deliberately no closing
    /// ritual ("check the result", "mark the task finished"): finishing is the
    /// person's own Complete, and a step that only repeats it is filler.
    private static func genericSteps(title: String, notesNonEmpty: Bool, language: Lang) -> [String] {
        if language == .hr {
            var steps = [
                "Napiši jednu rečenicu o tome kako izgleda gotovo.",
                "Napiši popis onoga što još treba obaviti.",
                "Otvori prvu stavku s popisa i napiši njezinu prvu rečenicu."
            ]
            if notesNonEmpty { steps.insert("Otvori bilješke i pročitaj ih do kraja.", at: 0) }
            return steps
        } else {
            var steps = [
                "Write one sentence about what done looks like.",
                "Write a list of what is still needed.",
                "Open the first item on the list and write its first line."
            ]
            if notesNonEmpty { steps.insert("Open the notes and read them from start to finish.", at: 0) }
            return steps
        }
    }

}
