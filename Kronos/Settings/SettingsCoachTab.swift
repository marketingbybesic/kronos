// Kronos/Settings/SettingsCoachTab.swift
// Feature G (Coach) + rev9 feature K (Today's blocks strip, learned links list). Every control
// here reads/writes `model.coach` (Kronos/Shared/CoachModel.swift) — never a second store.
// Calendar access is never requested implicitly: only the explicit "Allow calendar access"
// button in the calm allow row below calls `model.coach.requestCalendarAccess()`.
import SwiftUI
import AppKit
import KronosCore

struct SettingsCoachTab: View {
    let model: AppModel
    @State private var leadMinutes: Double
    @State private var morningPlanEnabled: Bool = AppearancePrefs.morningPlanEnabled
    @State private var timeBlocksEnabled: Bool = TimeBlocksPrefs.isEnabled
    @State private var menuBarFollowsBlock: Bool = TimeBlocksPrefs.menuBarFollows
    @State private var defaultEnergy: KEnergyLevel

    init(model: AppModel) {
        self.model = model
        _leadMinutes = State(initialValue: Double(model.coach.settings.blockLeadMinutes))
        _defaultEnergy = State(initialValue: model.coach.settings.presets.first { $0.id == OrdoPreset.coachID }?.energy ?? .mid)
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.coach.section.triage")) {
            SettingsRow(label: String(localized: "settings.coach.autotriage")) {
                Toggle(isOn: Binding(
                    get: { model.coach.settings.autoTriage },
                    set: { v in model.coach.update { $0.autoTriage = v } }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
            }
            SettingsHelpRow {
                Text(String(localized: "settings.coach.autotriage.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
            if model.coach.settings.autoTriage {
                fieldToggles
            }
        }

        SettingsSection(title: String(localized: "settings.coach.section.blocks")) {
            SettingsRow(label: String(localized: "settings.coach.blockcoach")) {
                Toggle(isOn: Binding(
                    get: { model.coach.settings.blockCoachEnabled },
                    set: { v in model.coach.update { $0.blockCoachEnabled = v }; Task { await model.coach.refreshBlocks() } }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
            }
            if model.coach.settings.blockCoachEnabled {
                SettingsRow(label: String(localized: "settings.coach.leadminutes")) {
                    HStack(spacing: Space.x2) {
                        Slider(value: $leadMinutes, in: 0...30, step: 5)
                            .frame(width: 140)
                            .onChange(of: leadMinutes) { _, v in model.coach.update { $0.blockLeadMinutes = Int(v) } }
                        Text(String(format: String(localized: "settings.coach.leadminutes.value"), leadMinutes))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                calendarsRow
                learnedLinksSection
                todaysBlocksSection
            }
        }

        SettingsSection(title: String(localized: "settings.coach.section.plan")) {
            SettingsRow(label: String(localized: "settings.coach.morningplan")) {
                Toggle(isOn: Binding(get: { morningPlanEnabled }, set: { v in
                    morningPlanEnabled = v
                    AppearancePrefs.morningPlanEnabled = v
                })) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
            }
            SettingsHelpRow {
                Text(String(localized: "settings.coach.morningplan.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
            SettingsRow(label: String(localized: "settings.coach.defaultenergy")) {
                KSegmented(selection: Binding(get: { defaultEnergy }, set: { newValue in
                    defaultEnergy = newValue
                    model.coach.update { settings in
                        if let i = settings.presets.firstIndex(where: { $0.id == OrdoPreset.coachID }) {
                            settings.presets[i].energy = newValue
                        }
                    }
                }), segments: [
                    KSegment(value: KEnergyLevel.low, text: String(localized: "energy.low")),
                    KSegment(value: KEnergyLevel.mid, text: String(localized: "energy.mid")),
                    KSegment(value: KEnergyLevel.high, text: String(localized: "energy.high")),
                ])
            }
        }

        SettingsSection(title: String(localized: "settings.coach.section.timeblocks")) {
            SettingsRow(label: String(localized: "settings.coach.timeblocks")) {
                Toggle(isOn: Binding(get: { timeBlocksEnabled }, set: { v in
                    timeBlocksEnabled = v
                    TimeBlocksPrefs.isEnabled = v
                })) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
            }
            // Controls whether the menu-bar item follows the current time block instead of
            // staying pinned to a project — MenuBarBlockFocus.swift (pure precedence rule,
            // hand-tested) reads this to decide which one leads the bar/popover.
            SettingsRow(label: String(localized: "settings.coach.timeblocks.menubarfollows")) {
                Toggle(isOn: Binding(get: { menuBarFollowsBlock }, set: { v in
                    menuBarFollowsBlock = v
                    TimeBlocksPrefs.menuBarFollows = v
                })) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .uiTestAnchor("settings.coach.timeblocks.menubarfollows")
            }
            SettingsHelpRow {
                Text(String(localized: "settings.coach.timeblocks.menubarfollows.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
        }
    }

    // MARK: Triage fields

    private var fieldToggles: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: "settings.coach.fields.title"))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
            KFlowRow(items: CoachTriageField.allCases) { field in
                fieldChip(field)
            }
        }
        .padding(.top, Space.x1)
    }

    private func fieldChip(_ field: CoachTriageField) -> some View {
        let isOn = model.coach.settings.triageMayFill.contains(field)
        return Button {
            model.coach.update { settings in
                if isOn { settings.triageMayFill.remove(field) } else { settings.triageMayFill.insert(field) }
            }
        } label: {
            HStack(spacing: Space.x1) {
                Icon(isOn ? "check" : "circle", size: Metrics.iconXS)
                Text(fieldLabel(field)).font(Typo.meta)
            }
            .foregroundStyle(isOn ? Tok.textPrimary : Tok.textTertiary)
            .padding(.horizontal, Space.x2)
            .frame(height: Metrics.controlCompact)
            .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(isOn ? Tok.controlFill : Color.clear))
            .kBorder(Tok.borderControl, radius: Radius.chip)
        }
        .buttonStyle(.plain)
    }

    private func fieldLabel(_ field: CoachTriageField) -> String {
        switch field {
        case .priority: return String(localized: "settings.coach.field.priority")
        case .effort: return String(localized: "settings.coach.field.effort")
        case .project: return String(localized: "settings.coach.field.project")
        case .depth: return String(localized: "settings.coach.field.depth")
        case .deadline: return String(localized: "settings.coach.field.deadline")
        case .firstMove: return String(localized: "settings.coach.field.firstmove")
        }
    }

    // MARK: Calendars — calm allow row when access is missing

    @ViewBuilder
    private var calendarsRow: some View {
        switch model.coach.calendarAccess {
        case .granted:
            SettingsHelpRow {
                Text(String(localized: "settings.calendars.title"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
        case .notDetermined:
            KAllowAccessRow(
                message: String(localized: "settings.coach.calendars.needsaccess"),
                buttonTitle: String(localized: "settings.calendars.grant")
            ) {
                Task { await model.coach.requestCalendarAccess() }
            }
        case .denied:
            // macOS asks only once. After a refusal the request is a no-op, so the only working
            // path is the Privacy pane; the status is re-read when the user comes back.
            KAllowAccessRow(
                message: String(localized: "settings.calendars.denied"),
                buttonTitle: String(localized: "settings.calendars.opensystem")
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.coach.refreshBlocks() }
            }
        }
    }

    // MARK: Learned links (feature K)

    @ViewBuilder
    private var learnedLinksSection: some View {
        let learned = model.coach.settings.learnedEventTitles
        if !learned.isEmpty {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(localized: "settings.coach.learned.title"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                    .padding(.top, Space.x2)
                ForEach(Array(learned.keys.sorted()), id: \.self) { title in
                    learnedLinkRow(eventTitle: title, projectID: learned[title])
                }
            }
        }
    }

    private func learnedLinkRow(eventTitle: String, projectID: UUID?) -> some View {
        let projectName = projectID.flatMap { id in model.store.allProjects(includeArchived: true).first { $0.id == id }?.name }
        return HStack {
            Text(eventTitle).font(Typo.row).foregroundStyle(Tok.textPrimary).lineLimit(1)
            Icon("arrow-right", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
            Text(projectName ?? String(localized: "settings.coach.learned.unknown"))
                .font(Typo.row).foregroundStyle(Tok.textSecondary).lineLimit(1)
            Spacer()
            Button(String(localized: "settings.coach.learned.forget")) {
                model.coach.forgetLearnedLink(eventTitle: eventTitle)
            }
            .kButton(.ghost, size: .compact)
            .fixedSize()
        }
        .frame(height: Metrics.controlRegular)
    }

    // MARK: Today's blocks strip (feature K)

    @ViewBuilder
    private var todaysBlocksSection: some View {
        if model.coach.calendarAccess == .granted {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(localized: "settings.coach.today.title"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                    .padding(.top, Space.x2)
                if model.coach.todaysBlocks.isEmpty {
                    Text(String(localized: "settings.coach.today.empty"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                } else {
                    ForEach(model.coach.todaysBlocks, id: \.event.id) { block in
                        todayBlockRow(block)
                    }
                }
            }
        }
    }

    private func todayBlockRow(_ block: (event: KCalendarEvent, projectID: UUID?)) -> some View {
        let projectName = block.projectID.flatMap { id in model.store.allProjects(includeArchived: true).first { $0.id == id }?.name }
        return HStack {
            Text(Self.timeFormatter.string(from: block.event.start))
                .font(Typo.mono)
                .foregroundStyle(Tok.textTertiary)
                .frame(width: 48, alignment: .leading)
            Text(block.event.title).font(Typo.row).foregroundStyle(Tok.textPrimary).lineLimit(1)
            Spacer()
            if let projectName {
                KBadge(projectName)
            } else {
                // A disabled stub here previously just deferred to the menu-bar's own
                // "This block is for..." control (MenuBarBlockBanner.linkPicker) — same
                // `model.coach.link(eventTitle:to:)` call and the same `KMenuButton` design-
                // system component, this row only needed its own menu of projects.
                KMenuButton(text: String(localized: "settings.coach.today.link")) {
                    ForEach(model.store.allProjects(includeArchived: false)) { project in
                        Button(project.name) { model.coach.link(eventTitle: block.event.title, to: project.id) }
                    }
                }
                .uiTestAnchor("settings.coach.today.link." + block.event.title)
            }
        }
        .frame(height: Metrics.controlRegular)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()
}

/// A simple wrapping row of same-height chips (triage field toggles). SwiftUI has no built-in
/// flow layout pre-macOS 14's `Layout` protocol usage here would be overkill for four items at
/// a fixed 760pt width — three-per-row covers every field name without truncation.
struct KFlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: Space.x2)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.x2) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
