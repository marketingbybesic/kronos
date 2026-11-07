// Hand-written table tests for the agent-facing run prompt (Kronos v1.2 "agent loop").
// RunPromptText is a pure function of its Input, so every shape rule the live-run bug exposed
// (missing First Move, MCP-instead-of-shell reporting, silent questions into a log) is pinned
// here hermetically, with no store.
import Foundation
import Testing
@testable import KronosCore

@Suite struct RunPromptTextTests {

    private let taskID = UUID(uuidString: "4F330C19-D664-4264-8F2B-51424CF400B3")!
    private let runID = UUID(uuidString: "AC9D7052-1514-4987-8E4D-F94F9F53DE35")!

    private func input(firstMove: String? = "Make an empty .md in Downloads named Hello",
                       rejectionComment: String? = nil,
                       ownerComments: [String] = [],
                       previousAttemptSummary: String? = nil) -> RunPromptText.Input {
        RunPromptText.Input(taskID: taskID, runID: runID, title: "Make a note",
                            firstMove: firstMove, priority: .low, dueDay: 20755, effort: .s,
                            notes: "Keep it short.", projectName: "Website Relaunch",
                            rejectionComment: rejectionComment, ownerComments: ownerComments,
                            previousAttemptSummary: previousAttemptSummary)
    }

    @Test func firstMoveIsPresentAndProminent() {
        let p = RunPromptText.build(input())
        #expect(p.contains("First move: Make an empty .md in Downloads named Hello"),
                "the live omp run asked 'what should the note say?' because this line was missing")
        // Prominent = part of the header block, directly under the title line.
        let header = p.components(separatedBy: "\n\n")[0]
        #expect(header.contains("Task: Make a note") && header.contains("First move:"))
        // positive control: no first move -> no empty "First move:" line.
        #expect(!RunPromptText.build(input(firstMove: "  ")).contains("First move:"))
    }

    @Test func reportingContractIsShellNotMCPAndCarriesTheRunID() {
        let p = RunPromptText.build(input())
        #expect(p.contains("kronos-cli --agent \"$KRONOS_AGENT\" call run_update"))
        #expect(p.contains("kronos-cli --agent \"$KRONOS_AGENT\" call run_finish"))
        #expect(p.contains(runID.uuidString), "the agent must never have to guess its run id")
        #expect(p.contains("DIFFERENT Kronos instance"),
                "must warn off the session's own registered Kronos MCP tools (the live failure mode)")
        #expect(p.contains("KRONOS_MCP_ENDPOINT_FILE") && p.contains("KRONOS_MCP_AGENT"))
        #expect(p.contains("Do not complete the task with complete_task."))
    }

    @Test func closingRuleForbidsAskingQuestionsIntoTheLog() {
        let p = RunPromptText.build(input())
        #expect(p.contains("it IS the action, not a question"))
        #expect(p.contains("run_finish outcome failed with exactly what is missing"))
        #expect(p.contains("Never ask a question into a log nobody reads."))
    }

    @Test func ownerFeedbackRendersCommentHistoryAndLastAttempt() {
        let p = RunPromptText.build(input(rejectionComment: "Dates were off by a day",
                                          ownerComments: ["c1", "c2", "c3", "c4", "c5", "c6"],
                                          previousAttemptSummary: "Added the .csv branch"))
        #expect(p.contains("Owner feedback:"))
        #expect(p.contains("The owner reviewed your last run and said: Dates were off by a day"))
        #expect(p.contains("Your last attempt: Added the .csv branch"))
        // Only the last 5 comments render: c1 dropped, c2...c6 kept.
        #expect(!p.contains("- c1") && p.contains("- c2") && p.contains("- c6"))
        // positive control: nothing to say -> the whole section is skipped.
        #expect(!RunPromptText.build(input()).contains("Owner feedback:"))
    }

    @Test func fieldsRenderOnlyWhenSet() {
        let p = RunPromptText.build(input())
        #expect(p.contains("Project: Website Relaunch"))
        #expect(p.contains("Priority: low"))
        #expect(p.contains("Effort: s"))
        // positive control: a bare input renders none of the optional field labels.
        let bare = RunPromptText.build(RunPromptText.Input(taskID: taskID, runID: runID, title: "T"))
        for label in ["Project:", "Priority:", "Due:", "Effort:", "Notes:", "Subtasks:", "Waits on:"] {
            #expect(!bare.contains(label), Comment(rawValue: label))
        }
    }
}
