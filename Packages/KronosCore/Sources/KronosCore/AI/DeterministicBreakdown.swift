// The deterministic half of "break a task into subtasks". PURE: no network,
// no store access. Step 1 reuses `DeterministicFirstMove.generate` — the
// same first-move template triage already falls back to — so a task's first
// subtask is always identical to its first move. Steps 2+ are a fixed,
// generic finish-the-task sequence (open/verify/finish/deliver), verb-family
// aware where `FirstMoveLint`'s allowlists make that possible, and every
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
    /// there, do the middle of the work, then close it out. Deliberately
    /// generic — the deterministic path cannot know the task's specifics,
    /// only that "started" needs 2 to 6 more concrete steps to reach "done".
    private static func genericSteps(title: String, notesNonEmpty: Bool, language: Lang) -> [String] {
        let obj = truncatedTitle(title, language: language)
        if language == .hr {
            var steps = [
                "Pročitaj \(obj) do kraja.",
                "Napiši popis onoga što još treba obaviti.",
                "Obavi prvu stavku s popisa."
            ]
            if notesNonEmpty { steps.insert("Otvori bilješke i pročitaj ih do kraja.", at: 0) }
            steps.append("Provjeri rezultat protiv izvornog zahtjeva.")
            steps.append("Označi zadatak završenim.")
            return steps
        } else {
            var steps = [
                "Read \(obj) from start to finish.",
                "Write a list of what is still needed.",
                "Do the first item on the list."
            ]
            if notesNonEmpty { steps.insert("Open the notes and read them from start to finish.", at: 0) }
            steps.append("Check the result against the original request.")
            steps.append("Mark the task finished.")
            return steps
        }
    }

    private static func truncatedTitle(_ title: String, language: Lang) -> String {
        let words = title.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? (language == .hr ? "zadatak" : "the task") : words
    }
}
