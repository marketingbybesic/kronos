// Kronos/DesignSystem/AppearancePrefs.swift
// Plain UserDefaults-backed preferences feature I needs that have no home yet in
// `CoachSettings` (Core, read-only reference for this leaf): which surfaces carry colour in
// Focus mode, what a row glyph is coloured by, and the menu-bar title's truncation width.
// `CoachSettings.density` / `.textSize` / `.nowCardEnabled` / `.accentHex` already exist —
// this file does NOT duplicate them. Hermetic under KRONOS_SNAPSHOT like every other
// controller in this directory (AISettingsController, MCPStatusProviding).
//
// Lives in Kronos/DesignSystem so `Chroma.tint`/`KProjectGlyph` — both in this same folder —
// can read `colourCarriers` directly without the design system importing the app layer.
// Settings keeps reading it by the same type/key names; nothing else changed.
//
// These four fields belong in `CoachSettings` long-term (so the menu bar / list / sidebar
// screens can read them the same way they read `nowCardEnabled`), but that file is frozen for
// now — this is the smallest working version.
import SwiftUI
import Observation

/// What may carry the user's colour in Focus mode (feature I). All four default ON, matching
/// today's shipped behaviour (a task's own project glyph, the Now card, sidebar project rows,
/// and the menu-bar title dot already show colour before this setting existed).
struct ColourCarriers: Codable, Equatable {
    var focusRowGlyph: Bool = true
    var nowCard: Bool = true
    var sidebarProject: Bool = true
    var menuBarTitle: Bool = true
}

/// What a row's glyph is coloured by, when colour is shown at all (feature I "colour by").
enum RowColourBy: String, Codable, CaseIterable {
    case project, priority, effort, none
}

extension ColourCarriers {
    /// Whether `carrier` may show hue right now, per feature I's checkboxes. `.other` (chips,
    /// gallery samples, anything not one of the four named surfaces) is always allowed — the
    /// carrier toggles only ever restrict the four named surfaces, never chrome.
    func allows(_ carrier: ChromaCarrier) -> Bool {
        switch carrier {
        case .rowGlyph: return focusRowGlyph
        case .nowCard: return nowCard
        case .sidebarProject: return sidebarProject
        case .menuBarTitle: return menuBarTitle
        case .other: return true
        }
    }
}

/// The colour a task ROW glyph should use, resolved from feature I's "colour by" setting.
/// `.useProjectColor` covers both `.project` mode and a `.priority`/`.effort` task whose
/// level is 0 (KPriority/KEffort `.none` — no attribute set, stays exactly like the unset
/// slots elsewhere in the row rather than looking "off"); `.override` is the mapped palette
/// swatch; `.neutral` is `.none` mode's explicit "always the neutral tone" — the one case
/// that must NOT fall back to the project's own colour.
enum RowGlyphColor {
    case useProjectColor
    case override(Color)
    case neutral
}

extension RowColourBy {
    /// Resolves which colour a task ROW glyph shows in Full mode (and the focus row in Focus
    /// mode) per feature I "colour by". `.priority`/`.effort` map the Core enum's raw level
    /// onto existing `KProjectPalette` swatches BY NAME (never a new colour — the palette has
    /// no red token and none may be added). Takes raw `Int` levels, not `KPriority`/`KEffort`
    /// directly, since the design system cannot import KronosCore; call with `task.priority
    /// .rawValue` / `task.effort.rawValue`.
    func resolvedColor(priorityLevel: Int, effortLevel: Int) -> RowGlyphColor {
        switch self {
        case .project: return .useProjectColor
        case .none: return .neutral
        case .priority:
            // 1...4 = low...urgent. Urgent maps to the warmest existing non-red swatch: orange
            // (hue 28 deg) is the warmest of the 12 with no red/red-adjacent hue at all —
            // amber/gold sit next, low gets the coolest of the four.
            let byLevel: [Int: String] = [1: "blue", 2: "gold", 3: "amber", 4: "orange"]
            guard let name = byLevel[priorityLevel], let color = swatch(named: name) else { return .neutral }  // unset = neutral: one meaning of colour per mode
            return .override(color)
        case .effort:
            // 1...5 = xs...xl, a second fixed cool-to-warm ramp so it never collides with
            // priority's own colours at a glance.
            let byLevel: [Int: String] = [1: "mint", 2: "teal", 3: "cyan", 4: "indigo", 5: "violet"]
            guard let name = byLevel[effortLevel], let color = swatch(named: name) else { return .neutral }  // unset = neutral: one meaning of colour per mode
            return .override(color)
        }
    }

    private func swatch(named name: String) -> Color? {
        KProjectPalette.swatches.first { $0.name == name }?.color
    }
}

enum AppearancePrefs {
    private static let carriersKey = "kronos.appearance.colourCarriers"
    private static let colourByKey = "kronos.appearance.colourBy"
    private static let morningPlanKey = "kronos.coach.morningPlanEnabled"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .snapshotScratch : .standard
    }

    static var colourCarriers: ColourCarriers {
        get {
            guard let data = defaults.data(forKey: carriersKey),
                  let decoded = try? JSONDecoder().decode(ColourCarriers.self, from: data) else {
                return ColourCarriers()
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: carriersKey)
        }
    }

    static var colourBy: RowColourBy {
        get { defaults.string(forKey: colourByKey).flatMap(RowColourBy.init(rawValue:)) ?? .project }
        set { defaults.set(newValue.rawValue, forKey: colourByKey) }
    }

    /// This tab's own toggle only persists the preference; the actual morning trigger (offers
    /// a short task set when Today or Inbox opens) is wired to this flag elsewhere — this
    /// file's part is this key existing and round-tripping.
    static var morningPlanEnabled: Bool {
        get { defaults.object(forKey: morningPlanKey) == nil ? true : defaults.bool(forKey: morningPlanKey) }
        set { defaults.set(newValue, forKey: morningPlanKey) }
    }
}

private extension UserDefaults {
    /// One throwaway suite per snapshot process, matching CoachModel's own hermetic pattern —
    /// never the real `kronos.appearance.*` keys during a gate run.
    static let snapshotScratch = UserDefaults(suiteName: "kronos.snapshot.appearance." + UUID().uuidString) ?? .standard
}

/// Makes `AppearancePrefs.colourCarriers` reactive for `KProjectGlyph` without the design
/// system taking an environment value from the app layer (that would need an edit to
/// `AppShellView`/`UIContract`, both outside this file). Each glyph holds one as `@State`;
/// `UserDefaults.didChangeNotification` fires on every write anywhere in the process
/// (Settings > Appearance's own toggles included), so a carrier flip repaints every glyph on
/// screen the same render pass a `\.chromaMode` environment change would.
@Observable
final class ChromaCarriersWatcher {
    private(set) var carriers = AppearancePrefs.colourCarriers
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.carriers = AppearancePrefs.colourCarriers }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
