// Kronos/Capture/CaptureFixtures.swift
// Snapshot-only sample data: neutral note text (Alex/Acme/Globex, never a real name) and a
// scripted `AIRouting` that exercises the upgrade-in-place path, with no network call. No
// production path constructs one — the app delegate wires the real router into `AppModel.ai`.
import Foundation
import KronosCore

enum CaptureFixtures {
    /// Mixed Croatian/English bullet dump, task-shaped lines, one of which folds to the
    /// same title as an existing open task so the duplicate note has something to show. Most
    /// lines carry a quick-add token (`#Project`, `!!`/`!!!`, `~s`/`~m`/`~l`, `sutra`) — a
    /// realistic note-taker who already knows the grammar types these even with AI off, so
    /// the offline demo shows populated attributes rather than an artificially bare list.
    /// The last task carries two indented, BULLETED subtask lines so the "generate tasks WITH
    /// subtasks" feature is visible in the review snapshot without anyone having to type an
    /// outline first. Bulleted (not plain) children: a plain lowercase line under a bulleted,
    /// non-stopper-ending parent is NoteSplitter's narrow "wrapped continuation" case (a
    /// hard-wrapped pasted title merges into it instead) — a bulleted child always stays a
    /// subtask regardless, which is the unambiguous shape for a fixture demoing the feature.
    /// "Call Alex..." carries a plain, unmarked follow-on line, exercising the "notes" shape:
    /// a bulleted task line, then a plain sentence with no marker of its own, becomes that
    /// task's notes rather than a bogus task or a subtask (NoteSplitter.notes(in:)).
    static let sampleNotes = """
    Acme sastanak:
    - Poslati Alex podsjetnik za ugovor #Acme !!! sutra
    - Review the Globex proposal deck #Globex ~m
    - Platiti račun za internet !! sutra
    - Book flight to the Globex offsite #Globex ~l !! sutra
    - Napisati prvi draft emaila klijentu ~s
    - Call Alex about the invoice #Acme ~xs
    He asked for the PDF version, not the scan.
    - Srediti račune za rujan ~m sutra
    - Pripremiti Globex prezentaciju #Globex ~m
      - poslati agendu timu
      - rezervirati salu za sastanak
    """

    /// One title that already exists as an open task in the harness seed's demo project, so
    /// `capture.review` can show a duplicate row unticked by default.
    static let existingOpenTitle = "Platiti račun za internet"

    /// A ~90-character title (measured: 94) with a project, priority, effort and due date all
    /// set — proves the title still wraps to 2 lines and tail-truncates WITH an ellipsis past
    /// that, on the SAME row as a full attributes line, rather than either one crowding the
    /// other out.
    static let longTitleNote = """
    - Poslati Alex detaljan sažetak sastanka s Globexom o obnovi ugovora i cijeni za sljedeću godinu #Acme !!! sutra
    """

    /// 40 task lines under a real `#Acme` project token (so the project column resolves
    /// instead of falling back to Inbox), most with 3 subtasks, every 5th with 8 — the review
    /// list's "stays fast with 200 lines" AND the "+N više" collapse-past-5 requirement both
    /// need a fixture this size to actually exercise (`capture.review.big`, gate G4).
    /// Deterministic (offline) on purpose: the point is list performance/layout at scale, not
    /// the AI upgrade path. `NoteSplitter.maxProposals` (30) caps the visible task count —
    /// intentional: it also exercises the "N more lines not shown" dropped-line notice.
    static let bigNote: String = {
        (1...40).map { i in
            let subtaskLines = (i % 5 == 0 ? (1...8) : (1...3)).map { "  - podzadatak \($0) za zadatak \(i)" }
            return (["- Zadatak \(i) #Acme"] + subtaskLines).joined(separator: "\n")
        }.joined(separator: "\n")
    }()

    /// A scripted `AIRouter` whose reply upgrades most lines (adds a first move, a project,
    /// resolves priority/effort) and adds one project the deterministic pass could not infer.
    /// `delay` lets a snapshot capture the "Improving with AI…" pending state before the
    /// reply lands (`capture.working`); real callers always use the default, zero delay.
    static func sampleRouter(delay: Duration = .zero) -> AIRouting {
        // The model answers in the app's own outline syntax (numbered task lines with priority and
        // effort markers), which the same parser as a typed line reads; titles repeat the pasted
        // text so the grounding guard keeps every one.
        let reply = #"""
        <tasks>
        1. Poslati Alex podsjetnik za ugovor !!!! ** #Acme
        2. Review the Globex proposal deck !! ** #Globex
        3. Platiti račun za internet !! *
        4. Book flight to the Globex offsite !!! *** #Globex
        5. Napisati prvi draft emaila klijentu !! *
        6. Call Alex about the invoice !! *xs #Acme
        7. Srediti račune za rujan !! **
        </tasks>
        """#
        let client = FixtureAIClient(modelID: "example-model", script: [.content(reply)], delay: delay)
        return AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
    }
}
