// Kronos/MenuBar/MenuBarPrefs.swift
// What the status item shows (subtask/task order) and how wide it is allowed to grow, both
// editable in Settings > Ordo. Hermetic under KRONOS_SNAPSHOT, same pattern as
// Kronos/DesignSystem/AppearancePrefs.swift (a throwaway UserDefaults suite per snapshot
// process, never the real `kronos.menubar.*` keys during a gate run).
import Foundation

/// "Menu bar shows" (brief 14a item 3). Composition always puts the SUBTASK before the TASK
/// when both are shown — this enum only controls WHICH parts appear, not their relative order.
enum MenuBarTitleMode: String, CaseIterable, Codable {
    case subtaskThenTask, taskThenSubtask, subtaskOnly, taskOnly
}

/// Compact/Medium/Wide/Full (brief 14a item 4). Full is capped, not unlimited — an
/// unbounded title would let one task push every other menu-bar-extra off the bar.
enum MenuBarWidth: String, CaseIterable, Codable {
    case compact, medium, wide, full

    /// Max characters of the COMPOSED title (subtask + separator + task already joined) before
    /// tail-truncation kicks in. Full's cap is stated in its own settings help text.
    var maxChars: Int {
        switch self {
        case .compact: return 18
        case .medium: return 30
        case .wide: return 46
        case .full: return 72
        }
    }
}

enum MenuBarPrefs {
    private static let modeKey = "kronos.menubar.titleMode"
    private static let widthKey = "kronos.menubar.width"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .snapshotScratch : .standard
    }

    static var titleMode: MenuBarTitleMode {
        get { defaults.string(forKey: modeKey).flatMap(MenuBarTitleMode.init(rawValue:)) ?? .subtaskThenTask }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    private static let fillKey = "kronos.menubar.fillToCamera"
    private static let pointsKey = "kronos.menubar.maxPoints"
    static let pointsRange: ClosedRange<Double> = 120...900

    /// The title runs all the way to the camera housing. Default on.
    static var fillToCamera: Bool {
        get { defaults.object(forKey: fillKey) == nil ? true : defaults.bool(forKey: fillKey) }
        set { defaults.set(newValue, forKey: fillKey) }
    }

    /// Exact width of the whole status item in points, used when `fillToCamera` is off.
    static var maxPoints: Double {
        get { let v = defaults.double(forKey: pointsKey); return v > 0 ? min(max(v, pointsRange.lowerBound), pointsRange.upperBound) : 360 }
        set { defaults.set(newValue, forKey: pointsKey) }
    }

    static var width: MenuBarWidth {
        get { defaults.string(forKey: widthKey).flatMap(MenuBarWidth.init(rawValue:)) ?? .full }
        set { defaults.set(newValue.rawValue, forKey: widthKey) }
    }
}

private extension UserDefaults {
    /// One throwaway suite per snapshot process, matching AppearancePrefs' own hermetic pattern.
    static let snapshotScratch = UserDefaults(suiteName: "kronos.snapshot.menubar." + UUID().uuidString) ?? .standard
}
