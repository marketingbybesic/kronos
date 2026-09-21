// Kronos/Settings/SettingsNotesTab.swift
// "Capture & Notes": the Notes inbox folder name, a "Test access" that calmly reports what
// `model.notes` can see, the meeting-capture hotkey (QuickAdd owns the actual global
// registration; this tab only shows/records it once that Name exists), and a short redaction
// note (PrivacyRedactor runs before anything captured reaches AI — spec reference only, this
// tab does not configure it further).
import AppKit
import SwiftUI
import KronosCore
import KeyboardShortcuts

struct SettingsNotesTab: View {
    let model: AppModel
    @State private var inboxFolder: String
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing
        /// `folders()` succeeded AND a folder named `inboxFolder` is among
        /// them — `count` is the total folders found ("Folders found: N").
        case ok(count: Int)
        /// `folders()` succeeded but no folder is named `inboxFolder` —
        /// distinct from `.needsAccess`: this is not a permission problem,
        /// the folder just does not exist (yet, or a typo). Lists up to 3 of
        /// the folders that DO exist so the right name can be spotted.
        case folderNotFound(existing: [String])
        case needsAccess
        case failed
    }

    init(model: AppModel) {
        self.model = model
        _inboxFolder = State(initialValue: model.coach.settings.notesInboxFolder)
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.notes.section.inbox")) {
            SettingsRow(label: String(localized: "settings.notes.folder")) {
                KTextField("Kronos", text: $inboxFolder)
                    .frame(width: SettingsMetrics.trailingColumn)
                    .onChange(of: inboxFolder) { _, v in model.coach.update { $0.notesInboxFolder = v } }
            }
            SettingsHelpRow {
                Text(String(localized: "settings.notes.folder.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }

            switch testState {
            case .idle, .testing:
                SettingsTrailingRow {
                    Button {
                        Task { await testAccess() }
                    } label: {
                        if testState == .testing {
                            HStack(spacing: Space.x2) { ProgressView().controlSize(.small); Text(String(localized: "settings.notes.test")) }
                        } else {
                            Text(String(localized: "settings.notes.test"))
                        }
                    }
                    .kButton(.secondary, size: .compact)
                    .disabled(testState == .testing)
                }
            case .ok(let count):
                SettingsHelpRow {
                    Text(String(format: String(localized: "settings.notes.test.ok"), count))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textSecondary)
                    Spacer()
                    Button(String(localized: "settings.notes.test")) { Task { await testAccess() } }
                        .kButton(.ghost, size: .compact)
                        .fixedSize()
                }
            case .folderNotFound(let existing):
                SettingsHelpRow {
                    VStack(alignment: .leading, spacing: Space.x1) {
                        Text(String(format: String(localized: "settings.notes.test.notfound"), inboxFolder))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textSecondary)
                        if !existing.isEmpty {
                            Text(String(format: String(localized: "settings.notes.test.notfound.existing"), existing.joined(separator: ", ")))
                                .font(Typo.meta)
                                .foregroundStyle(Tok.textTertiary)
                        }
                    }
                    Spacer()
                    Button(String(localized: "settings.notes.test")) { Task { await testAccess() } }
                        .kButton(.ghost, size: .compact)
                        .fixedSize()
                }
            case .needsAccess:
                KAllowAccessRow(
                    message: String(localized: "settings.notes.needsaccess"),
                    buttonTitle: String(localized: "settings.notes.opensettings")
                ) {
                    openAutomationSettings()
                }
            case .failed:
                SettingsHelpRow {
                    Text(String(localized: "settings.notes.test.failed"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer()
                    Button(String(localized: "settings.notes.test")) { Task { await testAccess() } }
                        .kButton(.ghost, size: .compact)
                        .fixedSize()
                }
            }
        }

        SettingsSection(title: String(localized: "settings.notes.section.capture")) {
            SettingsRow(label: String(localized: "settings.notes.hotkey")) {
                if let keys = HotkeyRegistry.current(for: "global.meetingcapture")?.displayKeys {
                    keyCaps(keys)
                }
            }
            SettingsHelpRow {
                Text(String(localized: "settings.notes.hotkey.pending"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
            SettingsHelpRow {
                Text(String(localized: "settings.notes.redaction"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
        }
    }

    /// `KKeyHint` only takes a variadic `String...`, not an array — spelled out per arity
    /// rather than reimplementing its body (same reasoning as `SettingsShortcutsTab.keyCaps`).
    @ViewBuilder
    private func keyCaps(_ keys: [String]) -> some View {
        switch keys.count {
        case 0: EmptyView()
        case 1: KKeyHint(keys[0])
        case 2: KKeyHint(keys[0], keys[1])
        case 3: KKeyHint(keys[0], keys[1], keys[2])
        default: KKeyHint(keys[0], keys[1], keys[2], keys[3])
        }
    }

    /// "Test access" answers the real question — "will my inbox folder be
    /// found?" — not just "did osascript run". A trimmed, empty
    /// `inboxFolder` never matches any real folder name, so it is treated
    /// like any other not-found case rather than silently reporting `.ok`.
    @MainActor
    private func testAccess() async {
        testState = .testing
        do {
            let folders = try await model.notes.folders()
            let wanted = inboxFolder.trimmingCharacters(in: .whitespaces)
            if folders.contains(where: { $0.name == wanted }) {
                testState = .ok(count: folders.count)
            } else {
                testState = .folderNotFound(existing: Array(folders.prefix(3).map(\.name)))
            }
        } catch NotesError.notAuthorised, NotesError.timedOut {
            testState = .needsAccess
        } catch {
            testState = .failed
        }
    }

    private func openAutomationSettings() {
        guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
