// Packages/KronosCore/Sources/KronosCore/Contracts/SelectionHue.swift
// Which hue a selection (a selected row's fill and left bar) or a view header's mark is drawn
// in. Pure and UI-free so a hand-written table can pin it down: the app maps the result to a
// concrete colour (`.project` -> that project's own colour, `.accent` -> the user's accent,
// `.white` -> the neutral white treatment). Hue only ever comes from a project's colour or the
// user's accent; the neutral (monochrome) colour mode forces white over both.
import Foundation

public enum SelectionHue: Equatable, Sendable {
    /// The project's own colour, as the "#RRGGBB" string stored on `KProject.colorHex`.
    case project(hex: String)
    /// The accent the user picked in Settings > Appearance.
    case accent
    /// Neutral white: the monochrome colour mode, never a hue.
    case white

    /// `projectHex` is the task's own project colour, `parentProjectHex` the colour of its parent
    /// task's project (a child inherits it). A missing or malformed hex is "no project": it falls
    /// through to the parent and then to the accent. `neutral` (monochrome mode) wins over all.
    public static func resolve(projectHex: String?, parentProjectHex: String? = nil, neutral: Bool) -> SelectionHue {
        if neutral { return .white }
        if let hex = validHex(projectHex) { return .project(hex: hex) }
        if let hex = validHex(parentProjectHex) { return .project(hex: hex) }
        return .accent
    }

    /// A task's row: its own project, else its parent's, else the accent.
    public static func forTask(_ task: KTask, neutral: Bool) -> SelectionHue {
        resolve(projectHex: task.project?.colorHex, parentProjectHex: task.parent?.project?.colorHex, neutral: neutral)
    }

    /// "#RRGGBB" or "RRGGBB" (any case) -> normalised "#RRGGBB"; anything else -> nil.
    static func validHex(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, UInt32(s, radix: 16) != nil else { return nil }
        return "#" + s.uppercased()
    }
}
