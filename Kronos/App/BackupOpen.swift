// Kronos/App/BackupOpen.swift
// A `.kronos.json` file opened from Finder (double click, "Open With", drop on the Dock icon).
// Never imported silently: the same counts summary Settings > Data shows, then an explicit Merge or Cancel.
// Merge only: "Replace everything" needs the typed confirmation that lives in Settings > Data, so this
// path cannot destroy anything. Reuses Settings' existing strings.
import AppKit
import SwiftUI
import KronosCore

struct BackupOpenView: View {
    let envelope: KronosExportEnvelope
    let fileName: String
    var onMerge: () -> Bool = { true }
    @State private var failed = false
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text(String(localized: "settings.data.import.label"))
                .font(Typo.title)
                .foregroundStyle(Tok.textPrimary)
            Text(fileName)
                .font(Typo.mono)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(String(format: String(localized: "settings.data.import.summary"),
                        String(envelope.tasks.count), String(envelope.projects.count), String(envelope.areas.count)))
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
            if failed {
                Text(String(localized: "settings.data.import.failed")).font(Typo.meta).foregroundStyle(Tok.textTertiary)
            }
            HStack(spacing: Space.x2) {
                Button(String(localized: "settings.data.import.merge")) { failed = !onMerge() }
                    .kButton(.primary)
                    .keyboardShortcut(.defaultAction)
                Button(String(localized: "common.cancel")) { onCancel() }
                    .kButton(.ghost)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Space.x5)
        .frame(width: 460)
        .background(Tok.bg)
    }
}

@MainActor
enum BackupOpen {
    private static var window: NSWindow?

    static func present(_ url: URL, model: AppModel) {
        guard AppDelegate.shared?.launchFailure == nil, url.lastPathComponent.lowercased().hasSuffix(".json") else { return }
        // An unreadable or foreign file is ignored the way a bad URL is: the file stays untouched.
        guard let envelope = try? BackupFile.read(from: url) else { return }
        window?.close()
        let view = BackupOpenView(envelope: envelope, fileName: url.lastPathComponent, onMerge: {
            guard Self.merge(envelope, model: model) else { return false }
            window?.close()
            return true
        }, onCancel: { window?.close() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view.preferredColorScheme(.dark)))
        w.title = String(localized: "settings.data.import.label")
        w.styleMask = [.titled, .closable]
        w.backgroundColor = .black
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// No toast on success: the undo pill would offer to undo an unrelated step, and the data is visible.
    private static func merge(_ envelope: KronosExportEnvelope, model: AppModel) -> Bool {
        guard let data = try? KronosExportCodec.makeEncoder().encode(envelope),
              (try? KronosImporter(store: model.store).importData(data, mode: .merge)) != nil else { return false }
        model.didMutate()
        return true
    }
}
