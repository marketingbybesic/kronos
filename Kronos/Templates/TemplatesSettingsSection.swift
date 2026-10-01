// Kronos/Templates/TemplatesSettingsSection.swift
// Settings > Data > "Templates": every saved template with an inline rename field and a
// quiet Delete. Templates are created from a task's inspector footer ("Save as template"),
// so this list only manages them. Included in the JSON export/import (SettingsDataTab).
import SwiftUI
import KronosCore

struct TemplatesSettingsSection: View {
    let store: TemplateStore

    var body: some View {
        SettingsSection(title: String(localized: "settings.data.templates")) {
            if store.templates.isEmpty {
                SettingsHelpRow {
                    Text(String(localized: "settings.data.templates.empty"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer()
                }
            } else {
                ForEach(store.templates) { t in
                    TemplateSettingsRow(template: t, store: store)
                }
            }
        }
    }
}

private struct TemplateSettingsRow: View {
    let template: TaskTemplate
    let store: TemplateStore
    @State private var draft: String

    init(template: TaskTemplate, store: TemplateStore) {
        self.template = template
        self.store = store
        _draft = State(initialValue: template.name)
    }

    var body: some View {
        HStack(spacing: Space.x2) {
            KTextField(String(localized: "settings.data.templates.rename"), text: $draft)
                .onSubmit(commit)
                .onChange(of: template.name) { _, new in draft = new }  // unique-ified or renamed elsewhere
            Spacer(minLength: Space.x2)
            Button(String(localized: "settings.data.templates.delete")) { store.delete(template.id) }
                .kButton(.ghost, size: .compact)
                .fixedSize()
        }
        .frame(height: Metrics.controlRegular)
        // Leaving the field without Return still keeps the edit (ADHD: no silent loss).
        .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { draft = template.name; return }
        store.rename(template.id, to: trimmed)
    }
}
