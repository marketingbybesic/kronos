// Kronos/Intents/KronosIntentEnums.swift. AppEnum wrappers over Core enums that Shortcuts
// needs to offer as a picker. Kept separate from the Core types themselves
// (KEnergyLevel, OrdoPreset) because `AppEnum` is an AppIntents conformance the Core
// package must not take on (it would pull AppIntents into every KronosCore consumer,
// including the MCP server and the unit test target).

import AppIntents
import KronosCore

// AppIntents phrases (titles, parameter names, entity/enum display names) are
// `LocalizedStringResource`, but MEASURED (not assumed): `appintentsmetadataprocessor` statically
// extracts these at build time and requires a literal resolved from the app's own main bundle in
// its OWN generated string catalog — `LocalizedStringResource(_:table:bundle:)` pointing at our
// hand-rolled Localizable.xcstrings hard-fails the build ("AppIntents requires
// 'LocalizedStringResource' to use the main bundle", "must be initialized with a call to its
// initializer or a string literal"). So these stay bare English string literals; `spokenName`
// below (a plain String, not part of the AppIntents metadata surface) is the one part of this
// file that DOES follow the app's UI language, via the ordinary catalog.
// GAP (not fixed): non-English phrases for AppIntents' own extracted catalog need Xcode's
// separate per-target string catalog for that generated table, which isn't reachable from
// scripts/add-strings.mjs / build-strings.mjs (those only ever target Localizable.xcstrings).
enum OrdoPresetOption: String, AppEnum {
    case deadline, quickwins, deepwork, priority, coach

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Ordo Preset"
    static var caseDisplayRepresentations: [OrdoPresetOption: DisplayRepresentation] = [
        .deadline: "Deadline",
        .quickwins: "Quick Wins",
        .deepwork: "Deep Work",
        .priority: "Priority",
        .coach: "Coach"
    ]

    /// The stable `OrdoPreset.id` string this option names (OrdoPreset.swift).
    var presetID: String {
        switch self {
        case .deadline: return OrdoPreset.deadlineID
        case .quickwins: return OrdoPreset.quickwinsID
        case .deepwork: return OrdoPreset.deepworkID
        case .priority: return OrdoPreset.priorityID
        case .coach: return OrdoPreset.coachID
        }
    }

    /// Confirmation copy for the spoken dialog, in the app's UI language — the five
    /// "ordo.preset.*" keys exist in the catalog.
    var spokenName: String {
        switch self {
        case .deadline: return String(localized: "ordo.preset.deadline")
        case .quickwins: return String(localized: "ordo.preset.quickwins")
        case .deepwork: return String(localized: "ordo.preset.deepwork")
        case .priority: return String(localized: "ordo.preset.priority")
        case .coach: return String(localized: "ordo.preset.coach")
        }
    }
}

enum EnergyOption: String, AppEnum {
    case low, mid, high

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Energy"
    static var caseDisplayRepresentations: [EnergyOption: DisplayRepresentation] = [
        .low: "Low", .mid: "Mid", .high: "High"
    ]

    var coreValue: KEnergyLevel {
        switch self {
        case .low: return .low
        case .mid: return .mid
        case .high: return .high
        }
    }
}
