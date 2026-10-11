// Kronos/Settings/SettingsAcknowledgementsView.swift
// Settings > About > Acknowledgements: the MIT license text for the two SPM dependencies
// (KeyboardShortcuts, MarkdownUI — the internal notes §3), verbatim, bundled as
// Kronos/Resources/Acknowledgements.md (same "plain .md resource" convention as
// Resources/Prompts/*.md) and rendered with MarkdownUI, which this screen is also the one
// place in the app that happens to exercise as a dependency.
import SwiftUI
import MarkdownUI

/// Pushed as a sheet from `SettingsAboutTab`'s "Acknowledgements" row.
struct SettingsAcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "settings.about.acknowledgements.missing")
        }
        return contents
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x5) {
                header
                Markdown(text)
                    .textSelection(.enabled)
            }
            .padding(Space.x6)
        }
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 640, minHeight: 320, idealHeight: 540)
        .background(Tok.bg)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "settings.about.acknowledgements"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            Spacer()
            Button(String(localized: "common.done")) { dismiss() }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("settings.acknowledgements.done")
        }
    }
}
