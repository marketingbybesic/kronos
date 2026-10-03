// Kronos/Triage/ReviewCardParts.swift
// What the Review card shows. One frame (the flow's own); nothing here draws another. Top to
// bottom: who proposed it, the title, why, where it came from, links, what "done" means, then
// what is proposed (the fields, the plan's tasks, or the change as a diff), then the decisions.
import SwiftUI
import KronosCore

extension TriageFlowView {

    // MARK: Card

    @ViewBuilder
    func reviewCard(for task: KTask) -> some View {
        if let item = reviewItem {
            VStack(alignment: .leading, spacing: Space.x4) {
                reviewByline(item)
                reviewTitle(item)
                if item.kind == .agentDone { agentDoneBody(item) } else { proposalBody(item) }
                reviewLinks(item)
                if let done = item.context.expectedOutcome, !done.isEmpty {
                    Text(String(format: String(localized: "review.donemeans"), done))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiTestAnchor("review.card.done")
                }
                if isRejecting || isReopening { reasonField(item) } else { reviewActions(item) }
            }
            .id(task.id)
        }
    }

    /// "From Relay", the agent's own name in tertiary text, with a quiet tag when it is unsure.
    private func reviewByline(_ item: ReviewItem) -> some View {
        let name = agentName(of: item.primary)
        let line = item.kind == .agentDone
            ? String(format: String(localized: "review.agentdone.says"), name)
            : String(format: String(localized: "review.from"), name)
        return HStack(spacing: Space.x2) {
            Text(line)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .uiTestAnchor("review.card.from")
            if item.context.isUnsure {
                KTag(String(localized: "review.unsure"), tone: Tok.textTertiary)
                    .uiTestAnchor("review.card.unsure")
            }
            Spacer(minLength: 0)
        }
    }

    private func agentName(of task: KTask) -> String {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil) {
        case .agent(let name): return name
        case .generic, .none: return String(localized: "review.agent.unnamed")
        }
    }

    private func reviewTitle(_ item: ReviewItem) -> some View {
        let target = item.kind == .update ? item.context.targetID.flatMap { model.store.task($0) } : nil
        let title = item.kind == .batch ? (item.context.proposalTitle ?? item.primary.title) : (target?.title ?? item.primary.title)
        return Text(title)
            .font(Typo.hero)
            .foregroundStyle(Tok.textPrimary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .uiTestAnchor("review.card.title")
    }

    // MARK: Proposal, plan, change

    @ViewBuilder
    private func proposalBody(_ item: ReviewItem) -> some View {
        if let why = item.context.reason {
            Text(why)
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .uiTestAnchor("review.card.why")
        }
        if let source = item.context.sourceTitle, !source.isEmpty {
            Text(String(format: String(localized: "review.source"), source))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
        }
        switch item.kind {
        case .batch: batchList(item)
        case .update: updateDiff(item)
        default: proposedFields(item)
        }
        if let twin = similarOpenTask(for: item) {
            Text(String(format: String(localized: "review.similar"), twin.title))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(2)
                .uiTestAnchor("review.card.similar")
        }
    }

    /// The fields as proposed: a quiet summary line, or the four editable rows once E opens them.
    @ViewBuilder
    private func proposedFields(_ item: ReviewItem) -> some View {
        let task = item.primary
        if isReviewEditing {
            VStack(alignment: .leading, spacing: Space.x3) {
                firstMoveBlock(for: task, writes: [])
                VStack(spacing: 0) {
                    KPropertyRow(String(localized: "viewoptions.field.priority")) { priorityMenu(for: task) }
                    KHairline()
                    KPropertyRow(String(localized: "viewoptions.field.effort")) { effortMenu(for: task) }
                    KHairline()
                    KPropertyRow(String(localized: "viewoptions.field.deadline")) { deadlineRow(for: task) }
                    KHairline()
                    KPropertyRow(String(localized: "viewoptions.field.project")) { projectMenu(for: task) }
                }
            }
            .uiTestAnchor("review.card.fields")
        } else {
            let line = fieldSummary(task)
            if !line.isEmpty {
                Text(line)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiTestAnchor("review.card.summary")
            }
        }
    }

    /// "High · Medium effort... " as one line of what is set; empty when the agent set nothing.
    private func fieldSummary(_ task: KTask) -> String {
        let today = Day.today(calendar: KronosLocale.calendar)
        var parts: [String] = []
        if task.priority != .none { parts.append(task.priority.localizedName) }
        if task.effort != .none { parts.append(task.effort.localizedName) }
        if let due = task.dueDay { parts.append(deadlineText(day: due, today: today)) }
        if let project = task.project?.name { parts.append(project) }
        return parts.joined(separator: " · ")
    }

    private func batchList(_ item: ReviewItem) -> some View {
        let shown = item.members.prefix(6)
        let more = item.members.count - shown.count
        return VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(format: String(localized: "review.batch.count"), item.members.count))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .padding(.bottom, Space.x1)
            ForEach(Array(shown), id: \.id) { member in
                Text(member.title)
                    .font(Typo.body)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(1)
            }
            if more > 0 {
                Text(String(format: String(localized: "review.batch.more"), more))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
        .uiTestAnchor("review.card.batch")
    }

    /// The proposed change line by line: the field, what it is now, what the agent wants.
    private func updateDiff(_ item: ReviewItem) -> some View {
        let target = item.context.targetID.flatMap { model.store.task($0) }
        return VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: "review.update.heading"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            ForEach(item.context.patch, id: \.key) { line in
                Text(diffText(line, target: target))
                    .font(Typo.body)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .uiTestAnchor("review.card.diff")
    }

    private func diffText(_ line: ReviewContext.PatchLine, target: KTask?) -> String {
        let today = Day.today(calendar: KronosLocale.calendar)
        let none = String(localized: "deadline.quick.none")
        func dayText(_ day: Int?) -> String { day.map { deadlineText(day: $0, today: today) } ?? none }
        func name(_ raw: String) -> String { raw.isEmpty ? none : raw }
        let label: String, from: String?, to: String
        switch line.key {
        case "due":
            label = String(localized: "viewoptions.field.deadline")
            from = target.map { dayText($0.dueDay) }
            to = dayText(Day.parseISO(line.value))
        case "plannedDay":
            label = String(localized: "review.field.planned")
            from = target.map { dayText($0.plannedDay) }
            to = dayText(Day.parseISO(line.value))
        case "priority":
            label = String(localized: "viewoptions.field.priority")
            from = target?.priority.localizedName
            to = KPriority.allCases.first { Self.wireName($0) == line.value }?.localizedName ?? line.value
        case "effort":
            label = String(localized: "viewoptions.field.effort")
            from = target?.effort.localizedName
            to = KEffort.allCases.first { Self.wireName($0) == line.value }?.localizedName ?? line.value
        case "project":
            label = String(localized: "viewoptions.field.project")
            from = target.map { name($0.project?.name ?? "") }
            to = name(line.value)
        case "title":
            label = String(localized: "review.field.title")
            from = target?.title
            to = line.value
        case "firstMove":
            label = String(localized: "detail.firstmove")
            from = target.map { name($0.firstMove ?? "") }
            to = name(line.value)
        case "notesAppend": label = String(localized: "review.field.notes"); from = nil; to = line.value
        case "labelsAdd": label = String(localized: "review.field.labels"); from = nil; to = line.value
        default: label = line.key; from = nil; to = line.value
        }
        guard let from, from != to else { return "\(label): \(to)" }
        return "\(label): \(from) → \(to)"
    }

    private static func wireName(_ p: KPriority) -> String {
        switch p { case .none: "none"; case .low: "low"; case .medium: "medium"; case .high: "high"; case .urgent: "urgent" }
    }
    private static func wireName(_ e: KEffort) -> String {
        switch e { case .none: "none"; case .xs: "xs"; case .s: "s"; case .m: "m"; case .l: "l"; case .xl: "xl" }
    }

    // MARK: Agent-done

    @ViewBuilder
    private func agentDoneBody(_ item: ReviewItem) -> some View {
        let result = ReviewResult(json: item.primary.resultJSON)
        if let note = result.note, !note.isEmpty {
            Text(note)
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .uiTestAnchor("review.card.note")
        }
    }

    // MARK: Links

    @ViewBuilder
    private func reviewLinks(_ item: ReviewItem) -> some View {
        let result = item.kind == .agentDone ? ReviewResult(json: item.primary.resultJSON).links : []
        let links = item.context.links + result
        if !links.isEmpty {
            KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    KChip(link.label, onTap: { openLink(link) }) {
                        Icon("globe", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                    }
                    .accessibilityLabel(link.label)
                }
            }
            .uiTestAnchor("review.card.links")
        }
    }

    /// Only http and https addresses open; anything else the agent sent stays text.
    private func openLink(_ link: ReviewContext.Link) {
        guard let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Decisions

    private func reviewActions(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
                switch item.kind {
                case .agentDone:
                    reviewButton(String(localized: "review.action.accept"), key: "⏎", anchor: "accept") { reviewApprove() }
                    reviewButton(String(localized: "review.action.reopen"), key: "R", anchor: "reopen") { reviewAskReason() }
                case .batch:
                    reviewButton(String(localized: "review.action.batch"), key: "⏎", anchor: "approve") { reviewApprove() }
                    reviewButton(String(localized: "review.action.reject"), key: "⌫", anchor: "reject") { reviewAskReason() }
                case .proposal:
                    reviewButton(String(localized: "review.action.approve"), key: "⏎", anchor: "approve") { reviewApprove() }
                    reviewButton(String(localized: "review.action.edit"), key: "E", anchor: "edit") { isReviewEditing.toggle() }
                    reviewButton(String(localized: "review.action.reject"), key: "⌫", anchor: "reject") { reviewAskReason() }
                    if similarOpenTask(for: item) != nil {
                        reviewButton(String(localized: "review.action.merge"), key: "M", anchor: "merge") { reviewMerge() }
                    }
                case .update:
                    reviewButton(String(localized: "review.action.approve"), key: "⏎", anchor: "approve") { reviewApprove() }
                    reviewButton(String(localized: "review.action.reject"), key: "⌫", anchor: "reject") { reviewAskReason() }
                }
                reviewButton(String(localized: "review.action.snooze"), key: "S", anchor: "snooze") { reviewSnooze() }
            }
            KKeyHintRow([(["esc"], String(localized: isReviewEditing ? "review.hint.back" : "triage.flow.hint.close"))])
        }
    }

    private func reviewButton(_ label: String, key: String, anchor: String,
                              kind: KButtonStyle.Kind = .secondary, action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            HStack(spacing: Space.x2) {
                Text(label)
                KKeyCap(key).accessibilityHidden(true)
            }
        }
        .kButton(kind, size: .compact)
        .fixedSize()
        .accessibilityLabel(label)
        .uiTestAnchor("review.action.\(anchor)")
    }

    /// Delete (reject) or R (reopen) asks for one line; Return sends it, Tab goes without, Esc backs out.
    private func reasonField(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            if isReopening {
                KTextField(String(localized: "review.reopen.prompt"), text: $reasonText)
                    .focused($isReasonFocused)
                    .accessibilityLabel(String(localized: "review.reopen.prompt"))
                    .uiTestAnchor("review.card.reason")
            } else {
                KTextField(String(localized: "review.reject.prompt"), text: $reasonText)
                    .focused($isReasonFocused)
                    .accessibilityLabel(String(localized: "review.reject.prompt"))
                    .uiTestAnchor("review.card.reason")
            }
            KKeyHintRow([
                (["⏎"], String(localized: isReopening ? "review.action.reopen" : "review.action.reject")),
                (["⇥"], String(localized: "review.hint.noreason")),
                (["esc"], String(localized: "review.hint.back")),
            ])
        }
    }
}
