// Kronos/Settings/SettingsPlanningTab.swift
// Planning: everything that shapes the day in one tab. Sorting new tasks and the house rules the
// model follows, the morning plan, calendar time blocks, the menu bar item. The Up next presets
// and the default preset per list change rarely, so they sit under Advanced.
import SwiftUI
import KronosCore

struct SettingsPlanningTab: View {
    let model: AppModel

    var body: some View {
        SettingsCoachTab(model: model)
        SettingsOrdoTab(model: model, part: .menuBar)
        SettingsAdvanced(tab: "planning") {
            SettingsOrdoTab(model: model, part: .presets)
        }
    }
}
