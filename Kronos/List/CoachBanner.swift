// Kronos/List/CoachBanner.swift — the block
// coach's Switch/Stay suggestion as a calm one-line banner above the Now card. Reads
// `model.coach.blockSuggestion` — the SAME state the menu bar popover answers, so acting here
// clears both (CoachModel is the single source of truth; this view never keeps its own copy).
// Never red, never modal: a plain hairline-bordered row, exactly one line of copy plus two
// quiet text actions, matching coach principle 4 ("never punish").
import SwiftUI
import KronosCore

struct CoachBanner: View {
    let model: AppModel
    /// Snapshot-only override: `model.coach.blockSuggestion` is `private(set)` and
    /// `CoachModel`'s calendar provider is fixed to `EventKitCalendar()` inside `AppModel`
    /// (Kronos/Shared/**), so a harness process — which never has real calendar access —
    /// cannot otherwise drive a suggestion onto the shared model. The real screen always
    /// calls `CoachBanner(model:)`, which reads the live suggestion; `CoachBannerSnapshots`
    /// below is the only caller that supplies this parameter. This is a known wiring gap:
    /// the clean fix is an injectable calendar in `AppModel.init`, at which point this
    /// parameter can be removed.
    var previewSuggestion: BlockSuggestion??

    private var suggestion: BlockSuggestion? {
        if let previewSuggestion { return previewSuggestion }
        return model.coach.blockSuggestion
    }

    var body: some View {
        if let suggestion {
            content(suggestion)
        }
    }

    private func content(_ suggestion: BlockSuggestion) -> some View {
        HStack(spacing: Space.x3) {
            Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            Text(bannerText(suggestion))
                .font(Typo.row)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Space.x3)
            Button(String(localized: "coach.block.stay")) { model.coach.stayInCurrent() }
                .kButton(.ghost, size: .compact)
            Button(String(localized: "coach.block.switch")) { model.coach.switchToBlock() }
                .kButton(.secondary, size: .compact)
        }
        .padding(.horizontal, Space.x3)
        .frame(height: Metrics.controlRegular)
        .kBorder(Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// "Acme block until 11:00" (starting) / "In the Acme block until 11:00" (already inside
    /// it after a wake/launch) — the two `BlockSuggestion.Kind`s read differently but never
    /// alarmingly (coach principle 4: a missed block is "Stay", not "Late").
    private func bannerText(_ s: BlockSuggestion) -> String {
        let time = Self.timeFormatter.string(from: s.endsAt)
        switch s.kind {
        case .starting:
            return String(format: String(localized: "coach.block.starting"), s.projectName, time)
        case .insideBlock:
            return String(format: String(localized: "coach.block.inside"), s.projectName, time)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("jm")
        return f
    }()
}

/// One-line mount point for `TaskListScreen`'s body (own padding + Calm-hiding baked in, so
/// the call site there is exactly one line) — kept here rather than inline in
/// TaskListScreen.swift to protect that file's own line budget.
struct CoachBannerSlot: View {
    let model: AppModel
    var previewSuggestion: BlockSuggestion?? = nil
    let isCalm: Bool

    var body: some View {
        if !isCalm {
            CoachBanner(model: model, previewSuggestion: previewSuggestion)
                .padding(.horizontal, Space.x4)
                .padding(.top, Space.x3)
        }
    }
}

/// Named snapshot screen for CoachBanner, merged into SnapshotHarness's registry. Seeds a
// scope, a project and a fixed block suggestion purely on `.onAppear` so the harness's
// shared registry construction never mutates the store eagerly.
//
// Compiled only outside Release: this is the harness-only tail of an otherwise-production
// file, wrapped rather than moved so the real CoachBanner/CoachBannerSlot types above stay
// untouched — see Kronos/Shared/SnapshotHarness.swift for why the harness is Release-inert.
#if !RELEASE
@MainActor
enum CoachBannerSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        ["list.blockbanner": AnyView(BlockBannerHost(model: model))]
    }
}

private struct BlockBannerHost: View {
    let model: AppModel
    @State private var didSeed = false
    @State private var project: KProject?

    var body: some View {
        TaskListScreen(model: model, previewBlockSuggestion: .some(project.map(makeSuggestion)))
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                model.scope = .all
                let projects = model.store.allProjects()
                let colorHex = (projects.first { $0.name == "Acme" } ?? projects.first)?.colorHex ?? KProjectPalette.swatches[0].color.hexString
                project = model.store.allProjects().first { $0.name == "Acme" }
                    ?? model.store.createProject(name: "Acme", colorHex: colorHex, icon: "briefcase", area: nil)
                model.didMutate()
            }
    }

    private func makeSuggestion(for project: KProject) -> BlockSuggestion {
        BlockSuggestion(eventID: "preview-event", projectID: project.id, projectName: project.name,
                        endsAt: Date().addingTimeInterval(35 * 60), kind: .starting)
    }
}
#endif
