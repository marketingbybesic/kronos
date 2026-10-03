#if !RELEASE
// Kronos/Triage/ReviewSnapshots.swift
// Named screens for Kronos/Shared/SnapshotHarness.swift: the Review card in each of its kinds.
// Seeding happens in the returned view's `.onAppear`, never while the dictionary is built.
import SwiftUI
import KronosCore

@MainActor
enum ReviewSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "review.card": AnyView(SeededReview(model: model, fixture: .proposal)),
            "review.batch": AnyView(SeededReview(model: model, fixture: .batch)),
            "review.update": AnyView(SeededReview(model: model, fixture: .update)),
            "review.agentdone": AnyView(SeededReview(model: model, fixture: .agentDone)),
            "review.reject": AnyView(SeededReview(model: model, fixture: .proposal, rejecting: true)),
            "review.empty": AnyView(ReviewEmpty(model: model)),
        ]
    }

    enum Fixture { case proposal, batch, update, agentDone }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func isoDay(_ day: Int) -> String {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Day.date(day, calendar: KronosLocale.calendar))
    }

    /// One agent-written task: pending (or awaiting a check), with the context the agent attached.
    @discardableResult
    static func proposal(_ store: TaskStore, title: String, review: Int = 1, context: [String: Any] = [:],
                         result: [String: Any]? = nil, assignee: Int = 0, project: KProject? = nil, status: KStatus = .todo,
                         priority: KPriority = .none, effort: KEffort = .none, dueDay: Int? = nil) -> KTask {
        let task = store.create(title: title, notes: "", project: project, status: status, priority: priority, dueDay: dueDay)
        store.updateNoUndo(task.id) {
            $0.effort = effort
            $0.needsTriage = false
            $0.source = "agent:research"
            $0.assigneeRaw = assignee
            $0.reviewRaw = review
            $0.contextJSON = context.isEmpty ? nil : json(context)
            $0.resultJSON = result.map(json)
        }
        return task
    }
}

private struct SeededReview: View {
    let model: AppModel
    let fixture: ReviewSnapshots.Fixture
    var rejecting = false
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TriageFlowView(model: model, onClose: {}, startMode: .review, startRejecting: rejecting)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            seed()
            model.didMutate()
            didSeed = true
        }
    }

    private func seed() {
        let store = model.store
        let today = Day.today(calendar: KronosLocale.calendar)
        switch fixture {
        case .proposal:
            let project = store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[10].hex, icon: "briefcase", area: nil)
            _ = store.create(title: "Send Index the corrected paragraph", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
            ReviewSnapshots.proposal(store, title: "Send Index the corrected paragraph", context: [
                "why": "Index asked for two corrections to the press release by Friday.",
                "source": ["kind": "email", "title": "Re: Press release draft"],
                "links": [["url": "https://example.com/draft-v3", "title": "Draft v3"],
                          ["url": "https://example.com/brief"]],
                "expectedOutcome": "Reply sent with the corrected paragraph",
                "confidence": 0.4,
            ], project: project, priority: .high, effort: .m, dueDay: today + 2)
        case .batch:
            let pid = UUID().uuidString
            for title in ["Book the venue", "Send the invitations", "Order the printed programmes", "Confirm the speakers"] {
                ReviewSnapshots.proposal(store, title: title, context: [
                    "why": "A plan for the March event.", "proposalID": pid, "proposalTitle": "March event",
                    "expectedOutcome": "Everything booked by the end of the month",
                ])
            }
        case .update:
            let target = store.create(title: "Call Index about the placement", notes: "", project: nil,
                                      status: .todo, priority: .medium, dueDay: today)
            ReviewSnapshots.proposal(store, title: "Call Index about the placement", context: [
                "kind": "update",
                "update": ["targetID": target.id.uuidString,
                           "patch": ["due": ReviewSnapshots.isoDay(today + 3), "priority": "high"],
                           "why": "The client moved the meeting to Monday."],
            ])
        case .agentDone:
            ReviewSnapshots.proposal(store, title: "Draft the reply to Index", review: 4, context: [
                "why": "Alex asked for a draft by noon.", "expectedOutcome": "A draft in the shared folder",
            ], result: [
                "note": "The draft is written and saved next to the press release.",
                "links": [["url": "https://example.com/draft-reply", "title": "Reply draft"]],
            ], assignee: 1)
        }
    }
}

private struct ReviewEmpty: View {
    let model: AppModel
    var body: some View { TriageFlowView(model: model, onClose: {}, startMode: .review) }
}
#endif
