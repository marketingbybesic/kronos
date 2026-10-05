// Kronos/Detail/InspectorReviewSection.swift
// The person's check of what an agent reports as done, on the task itself: Accept closes it, Reject
// sends it back, each with an optional comment the agent reads (get_task, events_poll). Only this
// person-side control writes a verdict; no MCP tool can. Once decided, the verdict stays visible.
import SwiftUI
import KronosCore

struct InspectorReviewSection: View {
    let model: AppModel
    let task: KTask
    @State private var comment = ""

    var body: some View {
        let _ = model.version
        Group {
            if task.reviewRaw == ReviewState.awaitingCheck {
                decision
            } else if task.agentID != nil, let result = AgentTaskResult.decode(task.resultJSON),
                      result.by == "me", let verdict = result.verdict {
                recap(result, verdict: verdict)
            }
        }
        .id(task.id)
    }

    // MARK: Waiting for the person

    private var decision: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(format: String(localized: "review.agentdone.says"), agentName))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
                .uiTestAnchor("inspector.review.says")
            if let note = AgentTaskResult.decode(task.resultJSON)?.note, !note.isEmpty {
                Text(note)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiTestAnchor("inspector.review.note")
            }
            KTextField(String(localized: "review.inspector.comment"), text: $comment)
                .uiTestAnchor("inspector.review.comment")
            HStack(spacing: Space.x2) {
                Button(String(localized: "review.action.accept")) {
                    ReviewVerdict.accept(task, comment: comment, model: model)
                }
                .kButton(.primary, size: .compact)
                .uiTestAnchor("inspector.review.accept")
                Button(String(localized: "review.action.reject")) {
                    ReviewVerdict.reject(task, comment: comment, model: model)
                }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("inspector.review.reject")
                Spacer(minLength: 0)
            }
            Text(String(localized: "review.inspector.help"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiTestAnchor("inspector.review")
    }

    private var agentName: String {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil) {
        case .agent(let name): return name
        case .generic, .none: return String(localized: "review.agent.unnamed")
        }
    }

    // MARK: Decided

    private func recap(_ result: AgentTaskResult, verdict: String) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: verdict == AgentReview.accepted ? "review.inspector.accepted" : "review.inspector.rejected"))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
            if let text = result.verdictComment, !text.isEmpty {
                Text(text)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiTestAnchor("inspector.review.verdict")
    }
}
