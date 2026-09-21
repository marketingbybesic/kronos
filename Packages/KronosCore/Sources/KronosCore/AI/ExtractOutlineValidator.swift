// `validateExtractOutline` and `extractOutlineBlock` are pure functions with no dependency
// on `AIRouter`'s own state (`mode`, `candidates`, `houseRules`) — split out here as a
// `public enum` of static functions so `scripts/extract-outline-parse.swift` (the
// capture-eval harness) can compile the REAL validator directly, instead of maintaining a
// hand-mirrored copy that can silently drift from the code it is supposed to be checking.
// Depends only on `NoteSplitter`, `KTextFold` (Contracts/Sorting.swift), `Day`/`ProposedTask`
// — all already compiled by the eval harness's launcher.
//
// Throws `ExtractOutlineError` (below), NOT `AIError`, and inlines its own tiny fence-strip
// helper rather than calling `OutputExtraction.stripFences`: `AIError` lives in
// `Contracts/AI.swift`, whose `AIRouting` protocol transitively pulls in `AIDTOs.swift` ->
// `RankingEngine.swift` -> `Runtime.swift` (`Ordering`) to resolve — and `OutputExtraction.swift`
// itself needs `AIError` too (its `decode<T>` throws it), so even that one file cannot be
// compiled alone. Both drag in half the package, which is why the harness's compiled
// source list stops here rather than keep re-widening. The inlined `stripFences`
// below is copied verbatim from `OutputExtraction.swift` (12 lines, no dependency of its own,
// unlikely to drift) — everything else stays a real, non-duplicated call into shared code.
// `AIRouter+Capture.swift` (which already has full access to `AIError`) converts
// `ExtractOutlineError` to `AIError.badJSON` at its one call site.
//
// `AIRouter.extractTasks` (AIRouter+Capture.swift) calls into this; nothing else changes about
// the feature's behaviour, only where the pure parsing/validation code lives.

import Foundation

/// What `ExtractOutlineValidator` throws — deliberately NOT `AIError` (see header comment
/// above). Carries the same "why" `AIError.badJSON(prefix:)` did; `AIRouter+Capture.swift`
/// converts this back to `AIError.badJSON` at its one call site so nothing downstream of that
/// conversion (the `rejectedCount` bookkeeping, `ExtractReason`) changes.
public enum ExtractOutlineError: Error, Equatable, Sendable {
    case emptyReply
    case nothingGrounded(lineCount: Int)
}

public enum ExtractOutlineValidator {

    /// Pulls the outline text between `<tasks>` and `</tasks>` (tolerant of prose or a code
    /// fence around it, same tolerance `OutputExtraction.braceSlice` gives the JSON prompts).
    /// Falls back to the whole trimmed reply when no tags are found, so a model that forgets
    /// the tags but otherwise follows the syntax is not punished for that alone — the per-line
    /// grammar and hallucination guard below are the real gate.
    ///
    /// Takes the LAST `<tasks>` in the reply, then the FIRST `</tasks>` that follows IT, rather
    /// than a naive first/first pair — a defensive shape for a model that preambles with a
    /// recap of its instructions before the real answer (small/free models do this): the
    /// GENUINE block is the one whose own close tag comes right after its own open tag with no
    /// closer alternative, which last-open-then-next-close finds even if `<tasks>`/`</tasks>`
    /// appear earlier in echoed prose too. (`PromptTemplates.extractSystem` itself is careful
    /// not to spell the literal tag strings anywhere outside the one real worked-example pair,
    /// precisely so this method's own test has nothing spurious to trip on — see
    /// `CaptureTests.capturePromptExampleParsesThroughTheRealParser`.)
    public static func extractOutlineBlock(_ text: String) -> String {
        let stripped = Self.stripFences(text)
        guard let start = stripped.range(of: "<tasks>", options: .backwards),
              let end = stripped.range(of: "</tasks>", range: start.upperBound..<stripped.endIndex) else {
            return stripped
        }
        return String(stripped[start.upperBound..<end.lowerBound])
    }

    /// Verbatim copy of `OutputExtraction.stripFences` (AI/OutputExtraction.swift) — that
    /// file's `decode<T>` needs `AIError`, so this enum cannot compile it in without the
    /// `AIError` dependency wall this file's header comment explains. This helper itself is
    /// dependency-free and 12 lines; if `OutputExtraction.stripFences` ever changes, update
    /// this copy too (there is no automated drift check for this one small function).
    private static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Content words used to fold-compare a title against the source for the hallucination
    /// guard: length >= 4 (folded), letters only, a short stop-word list excluded so common
    /// function words in either language never count as "grounding". Kept tiny and local
    /// rather than reusing `detectLanguage`'s HR-only stopword list, which is not meant for
    /// this purpose and has no English half.
    private static let contentStopWords: Set<String> = [
        // English
        "that", "this", "with", "from", "about", "into", "your", "their", "have", "will",
        "does", "been", "were", "what", "when", "where", "which",
        // Croatian (folded: đ->d, diacritics stripped)
        "koji", "koja", "koje", "sto", "cega", "nesto", "treba", "trebam", "moram", "danas",
        "sutra", "prekosutra", "kada", "gdje", "zasto", "kako", "radi", "buduci"
    ]

    public static func contentWords(_ s: String) -> Set<String> {
        Set(KTextFold.fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !contentStopWords.contains($0) })
    }

    /// Decodes the model's plain-text outline reply with the SAME grammar the deterministic
    /// paste path parses (`NoteSplitter.split`/`subtasks(in:)`/`notes(in:)`, which read
    /// `TaskOutline`'s indent rule and `QuickAddParser`'s tokens) — no second parser, no
    /// `sourceLine` field, no JSON. Replaces the old whole-line `sourceLine` hallucination guard
    /// with a content-word overlap check against the ORIGINAL source
    /// text: a task is kept when >= 60% of its title's content words appear in the source, OR
    /// its notes are a verbatim (folded) substring of the source — either is enough, since a
    /// short imperative title ("Get the file") can legitimately share almost no words with a
    /// long, specific notes sentence it is grounded in.
    ///
    /// THROWS when zero tasks survive: a JSON validator that instead returned `[]` as a normal,
    /// successful decode would never reach `hopAcrossModels`'s `catch` and so never hop to a
    /// fallback model. A reply with no task lines at all (the model correctly found nothing to
    /// do) is NOT an error — it decodes to zero source-level task LINES, which is different
    /// from "every task line was rejected by the guard"; both end up empty here on purpose,
    /// since the caller (`AIRouter.extractTasks`) cannot tell them apart from the outside
    /// either way and must hop regardless — a fallback model deserves the same chance to find
    /// nothing OR find something the first one missed.
    public static func validateExtractOutline(_ text: String, sourceText: String,
                                               projectNames: [String], today: Int) throws -> [ProposedTask] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExtractOutlineError.emptyReply
        }
        let deterministic = NoteSplitter.split(trimmed, today: today, projectNames: projectNames)
        let outlineSubtasks = NoteSplitter.subtasks(in: trimmed, projectNames: projectNames)
        let outlineNotes = NoteSplitter.notes(in: trimmed, projectNames: projectNames)
        let sourceFolded = KTextFold.fold(sourceText)
        // The ORIGINAL pasted lines, non-blank — used below to re-point each surviving AI
        // proposal's `sourceLine` at the actual input line it is grounded in (see the doc
        // comment on `p.sourceLine =` below for why this re-pointing is necessary at all).
        let sourceLines = sourceText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var out: [ProposedTask] = []
        for proposal in deterministic {
            // Every task line MUST carry priority and effort — `NoteSplitter.split` leaves
            // both at `.none` when `QuickAddParser` found no marker of that kind on the line,
            // so a reply that skipped either token is dropped here, never kept with a `.none`
            // default.
            guard proposal.priority != .none, proposal.effort != .none else { continue }

            let notes = outlineNotes[proposal.sourceLine]
            let groundedByNotes = notes.map { sourceFolded.contains(KTextFold.fold($0)) } ?? false
            let titleWords = contentWords(proposal.title)
            let matched = titleWords.filter { sourceFolded.contains($0) }
            let groundedByTitle = titleWords.isEmpty ? false
                : Double(matched.count) / Double(titleWords.count) >= 0.6
            guard groundedByTitle || groundedByNotes else { continue }

            var p = proposal
            p.notes = notes
            p.subtasks = outlineSubtasks[proposal.sourceLine] ?? []
            p.isFromAI = true
            // `proposal.sourceLine` up to here is the MODEL's own outline line (e.g. "Call Alex
            // about the invoice !! **") — meaningless to `CaptureModel.upgrade`, which matches an
            // AI proposal back onto the deterministic row it improves by CONTAINMENT against the
            // deterministic pass's `sourceLine`, itself always an ORIGINAL pasted line. Re-point
            // it at whichever original source line shares the most content words with this
            // proposal's title (falls back to the notes-matched line, then the model's own line
            // when the source has none — a single-line paste) so that containment match keeps
            // working unmodified downstream.
            if let notesLine = notes, let hit = sourceLines.first(where: { KTextFold.fold($0).contains(KTextFold.fold(notesLine)) }) {
                p.sourceLine = hit
            } else if let best = sourceLines.max(by: { a, b in
                contentWords(a).intersection(titleWords).count < contentWords(b).intersection(titleWords).count
            }), !contentWords(best).intersection(titleWords).isEmpty {
                p.sourceLine = best
            } else if let only = sourceLines.first, sourceLines.count == 1 {
                p.sourceLine = only
            }
            out.append(p)
        }
        guard !out.isEmpty else {
            throw ExtractOutlineError.nothingGrounded(lineCount: deterministic.count)
        }
        return out
    }
}
