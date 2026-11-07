// Kronos/Triage/ReviewNextRunSection.swift
// Split out of ReviewNextView.swift (500-line file cap): an agent-done card's own glance at
// its run (Kronos v1.2 Phase 2 "run contract", slice D2) — summary, artifacts, a static log
// tail. Collapsed by default; Space (ReviewNextKeys.swift) or this row's own disclosure button
// expand it. Read-only and non-live (no DispatchSource tail): a decision card, not a monitor —
// the richer live-tailing inspector belongs to slice C's own InspectorRunSection.swift.
import SwiftUI
import KronosCore

extension ReviewNextView {
    /// Nothing renders for a kind that never has a run, or a task with no run yet.
    @ViewBuilder
    func runSection(_ item: ReviewItem) -> some View {
        if item.kind == .agentDone, let run = LiveRuns.runs(taskID: item.primary.id).first {
            VStack(alignment: .leading, spacing: Space.x2) {
                runToggle
                if isRunExpanded { runDetail(run, cardNote: ReviewResult(json: item.primary.resultJSON).note) }
            }
        }
    }

    private var runToggle: some View {
        Button(action: { isRunExpanded.toggle() }) {
            HStack(spacing: Space.x1) {
                Icon(isRunExpanded ? "chevron-down" : "chevron-right", size: Metrics.iconS)
                Text(String(localized: "review.next.run.toggle"))
                    .font(Typo.meta)
                KKeyCap("Space").accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tok.textTertiary)
        .accessibilityLabel(String(localized: "review.next.run.toggle"))
        .accessibilityAddTraits(isRunExpanded ? [.isSelected] : [])
        .uiTestAnchor("review.next.run.toggle")
    }

    @ViewBuilder
    private func runDetail(_ run: KAgentRun, cardNote: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            // The normal "done" case: `run_finish`'s summary is the exact text `complete_task`
            // wrote as the card's own report (RunStore.finish calls AgentDoneReport.reportDone
            // with `note: summary`) — whatHappened(item) above already printed it. Only show it
            // again here when it says something the card text does not already say.
            let trimmedSummary = run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNote = (cardNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty, trimmedSummary != trimmedNote {
                Text(run.summary)
                    .font(Typo.body)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiTestAnchor("review.next.run.summary")
            }
            let artifacts = Self.decodeArtifacts(run.artifactsJSON)
            if !artifacts.isEmpty {
                KFlowLayout(spacing: Space.x1, lineSpacing: Space.x1) {
                    ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                        KTag(artifact.title ?? artifact.ref, tone: Tok.textTertiary)
                    }
                }
                .uiTestAnchor("review.next.run.artifacts")
            }
            if let tail = Self.logTail(run.logPath), !tail.isEmpty {
                Text(tail)
                    .font(Typo.mono)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(20)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .uiTestAnchor("review.next.run.log")
            }
        }
        .padding(.leading, Space.x4)
    }

    /// `RunArtifact.decodeList`/`encodeList` are internal to KronosCore; the type and its
    /// `kind`/`ref`/`title` fields are public and plainly `Codable`, so a vanilla decoder
    /// reads the same JSON `RunStore` wrote (no custom key strategy on either side).
    private static func decodeArtifacts(_ json: String) -> [RunArtifact] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        let decoded = (try? JSONDecoder().decode([RunArtifact].self, from: data)) ?? []
        // RunStore's own update/finish merges already skip a new artifact whose kind+ref
        // matches one already stored (RunStoreTests.swift pins both paths); this is a second,
        // cheap guard at the one place artifacts are rendered, so a kind+ref duplicate never
        // shows two chips even if one ever reached storage some other way.
        var seen = Set<[String]>()
        return decoded.filter { seen.insert([$0.kind, $0.ref]).inserted }
    }
    /// The last `lines` of the run's log, read once (not a live tail — see the file header).
    /// Capped to the trailing 8 KB so a long-running harness log is never fully loaded.
    private static func logTail(_ path: String, lines: Int = 20) -> String? {
        guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data.suffix(8192), as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }
}
