// SNAPSHOT HARNESS. Renders one named screen to a PNG and exits, against an
// IN-MEMORY store seeded from JSON, so a snapshot run never opens the user's real store
// (one process owns the real ModelContainer; a second writer is forbidden).
//
//   KRONOS_SNAPSHOT="<screen>:<width>x<height>:<absolute out.png>"   required
//   KRONOS_SEED=<absolute path to kronos-seed.json>                   optional (else empty store)
//   KRONOS_SNAPSHOT_SCOPE=inbox|today|next7|waiting|someday|all|firstProject   optional
//   KRONOS_SNAPSHOT_SELECT=first                                      optional: select first task
//   KRONOS_SNAPSHOT_CHROMA=focus|full|calm                            optional: colour mode
//   KRONOS_SNAPSHOT_SIDEBAR=icons                                     optional: icons-only rail
//   KRONOS_SNAPSHOT_PREFS=density=compact,text=S,carriers-none,colourby-priority   optional
//       comma list of appearance prefs applied to the hermetic
//       AppearancePrefs/ProjectPalettePrefs stores + DSScale BEFORE the view is built:
//       density=compact|regular, text=S|M|L, carriers-none (every carrier off; default all
//       on), colourby-project|priority|effort|none, palette-reordered (moves "graphite" to
//       the front — a deterministic fixture for "the picker shows the edited order").
//       gate-shots.mjs forwards a shot's own `prefs=` option here, converting its
//       `+`-joined sub-values back to commas.
//
// Built-in screens: "shell", "sidebar", "list", "inspector". Each UI leaf adds more (popover
// contents, empty states, the menu-bar popover…) by filling its `*Snapshots.screens(model:)`
// function — those live in the leaf's own directory, this file never changes.
//
// Technique: the hosting window is ordered front far off-screen and made key, so text fields
// get a real text context; pixels are captured from the laid-out NSView with cacheDisplay
// (an ImageRenderer pass would build a second, contextless SwiftUI tree).

import AppKit
import SwiftUI
import KronosCore

// Release stub: `isRequested` is read unconditionally by `KronosIntents.bootstrap(model:)`
// (Kronos/Intents/KronosIntents.swift:30, a file this leaf does not own), so the type must
// exist and keep that one member's signature in every config. Hardcoding `false` here means
// a Release binary can never be told to run the harness even if the env var were somehow set,
// and the real implementation (which pulls in every `*Snapshots.swift` registry) is compiled
// out entirely, so none of its code or fixture strings reach the linked binary.
#if RELEASE
@MainActor
enum SnapshotHarness {
    static var isRequested: Bool { false }
}
#else
@MainActor
enum SnapshotHarness {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil }

    /// Called from the app delegate INSTEAD of normal launch when `isRequested`.
    static func run(store: TaskStore) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["KRONOS_SNAPSHOT"] else { return }
        let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
        let dims = parts.count > 1 ? parts[1].split(separator: "x").compactMap { Double($0) } : []
        guard parts.count == 3, dims.count == 2 else { fail("bad KRONOS_SNAPSHOT spec: \(spec)") }
        let (screen, size, out) = (parts[0], NSSize(width: dims[0], height: dims[1]), parts[2])

        if let seed = env["KRONOS_SEED"], let data = try? Data(contentsOf: URL(fileURLWithPath: seed)) {
            do { _ = try JSONImporter(store: store).importJSON(data) } catch { fail("seed import failed: \(error)") }
        }
        if let prefs = env["KRONOS_SNAPSHOT_PREFS"] { applySnapshotPrefs(prefs) }
        let model = AppModel(store: store)
        model.sidebarIconsOnly = env["KRONOS_SNAPSHOT_SIDEBAR"] == "icons"
        if let c = env["KRONOS_SNAPSHOT_CHROMA"].flatMap(ChromaMode.init(rawValue:)) { model.chromaMode = c }
        switch env["KRONOS_SNAPSHOT_SCOPE"] {
        case "today": model.scope = .today
        case "next7": model.scope = .next7
        case "waiting": model.scope = .waiting
        case "someday": model.scope = .someday
        case "all": model.scope = .all
        case "firstProject": if let p = store.allProjects().first { model.scope = .project(p.id) }
        default: model.scope = .inbox
        }
        if env["KRONOS_SNAPSHOT_SELECT"] == "first" {
            model.selectedTaskID = KTaskSorter.sorted(store.allTasks(), by: KSortDescriptor.default).first?.id
        }

        var screens: [String: AnyView] = [
            "shell": AnyView(AppShellView(model: model)),
            "sidebar": AnyView(SidebarScreen(model: model)),
            "list": AnyView(TaskListScreen(model: model)),
            "inspector": AnyView(InspectorScreen(model: model)),
            "impuls": AnyView(ImpulsScreen(model: model)),
            "settings": AnyView(SettingsScreen(model: model)),
            "palette": AnyView(CommandPaletteView(model: model)),
        ]
        // Registries are built lazily per leaf: a builder must NOT mutate the store or the model
        // at construction time (two leaves leaked state into every screen that way) — do it in
        // the returned view's `.onAppear`.
        for extra in [SidebarSnapshots.screens(model: model), ListSnapshots.screens(model: model),
                      DetailSnapshots.screens(model: model), MenuBarSnapshots.screens(model: model),
                      ImpulsSnapshots.screens(model: model), PaletteSnapshots.screens(model: model),
                      SettingsSnapshots.screens(model: model), CaptureSnapshots.screens(model: model),
                      CoachBannerSnapshots.screens(model: model),
                      QuickAddSnapshots.screens(model: model),
                      PermissionsSnapshots.screens(model: model),
                      TriageSnapshots.screens(model: model),
                      TimeBlocksSnapshots.screens(model: model),
                      WelcomeSnapshots.screens(model: model)] {
            screens.merge(extra) { _, new in new }
        }
        guard let view = screens[screen] else {
            fail("unknown screen '\(screen)'. Available: \(screens.keys.sorted().joined(separator: ", "))")
        }

        // Reactive: a fixture may set `model.chromaMode` in its own `.onAppear`; a value captured
        // here once would freeze the mode before that runs.
        let root = SnapshotChromaRoot(model: model) { view }
            .frame(width: size.width, height: size.height)
            .background(Color.black).preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()

        // Let SwiftUI settle (onAppear fetches, animations) before capturing.
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            MainActor.assumeIsolated { capture(hosting, size: size, to: out) }
        }
    }

    private static func capture(_ hosting: NSView, size: NSSize, to path: String) {
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("no bitmap rep") }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let px = NSSize(width: size.width * 2, height: size.height * 2)
        guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("no scaled rep") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: px).fill()
        rep.draw(in: NSRect(origin: .zero, size: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = scaled.representation(using: .png, properties: [:]) else { fail("png encode") }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("write \(path): \(error)") }
        print("SNAPSHOT OK \(path) \(Int(px.width))x\(Int(px.height))")
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("SNAPSHOT FAIL: " + message + "\n").utf8))
        exit(1)
    }

    /// Parses `KRONOS_SNAPSHOT_PREFS` and writes each recognised token
    /// straight to the hermetic `AppearancePrefs`/`ProjectPalettePrefs` stores (already
    /// snapshot-scoped by `KRONOS_SNAPSHOT`, same guard those types use) plus `DSScale` — the
    /// same two calls AppDelegate makes for a real launch. Runs before `AppModel(store:)` so
    /// every screen it builds already sees the requested prefs, matching AppDelegate's own
    /// "read once before the first window" contract. An unrecognised token is ignored rather
    /// than failing the shot — gate-shots specs are the only callers and are trusted input.
    private static func applySnapshotPrefs(_ spec: String) {
        var density = "regular", text = "M"
        for token in spec.split(separator: ",").map(String.init) {
            if let eq = token.firstIndex(of: "=") {
                let key = String(token[token.startIndex..<eq]), value = String(token[token.index(after: eq)...])
                switch key {
                case "density": density = value
                case "text": text = value
                default: break
                }
            } else if token == "carriers-none" {
                AppearancePrefs.colourCarriers = ColourCarriers(focusRowGlyph: false, nowCard: false,
                                                                 sidebarProject: false, menuBarTitle: false)
            } else if token == "palette-reordered" {
                // Deterministic reorder for a gate/manual shot to prove against: moves the last
                // base swatch (graphite) to the front — anything visibly not in the shipped
                // amber-first order proves `ProjectPalettePrefs`/`KProjectPalette.orderedSwatches`
                // round-trip through the picker, without hand-editing Settings in a screenshot.
                var slots = ProjectPalettePrefs.slots
                if let i = slots.firstIndex(where: { $0.baseName == "graphite" }) {
                    slots.insert(slots.remove(at: i), at: 0)
                }
                ProjectPalettePrefs.slots = slots
            } else if let dash = token.firstIndex(of: "-"), token[token.startIndex..<dash] == "colourby" {
                let value = String(token[token.index(after: dash)...])
                if let by = RowColourBy(rawValue: value) { AppearancePrefs.colourBy = by }
            }
        }
        DSScale.apply(density: density, textSize: text)
    }
}

/// Re-reads the observable model on every render so the colour mode follows the fixture.
private struct SnapshotChromaRoot<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: () -> Content
    var body: some View { content().environment(\.chromaMode, model.chromaMode) }
}
#endif
