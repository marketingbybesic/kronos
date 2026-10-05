// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Named snapshot screens for Capture. Builders must not mutate at construction time (a
// SwiftUI `body` can be evaluated more than once) — all seeding happens inside the returned
// view's `.onAppear`.
import SwiftUI
import AppKit
import KronosCore

/// Round-trips a `KProjectPalette` swatch back to `KProject.colorHex` for seeding. Every leaf
/// that seeds a coloured project this way keeps its own copy (see Kronos/DesignSystem/
/// ColorHexString.swift's own note: "Two UI leaves each wrote a private copy in isolation");
/// this one is scoped to snapshot fixtures only.
private extension Color {
    var captureHexString: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

@MainActor
enum CaptureSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "capture": AnyView(SeededCaptureScreen(model: model, seed: .emptyPaste)),
            // The "Use AI" switch + model name row only has something to show when a router is
            // actually configured while still on the paste step — every OTHER AI-seeded variant
            // below preloads straight into `.review`.
            "capture.paste.ai": AnyView(SeededCaptureScreen(model: model, seed: .pasteWithAI)),
            "capture.working": AnyView(SeededCaptureScreen(model: model, seed: .aiPending)),
            "capture.review": AnyView(SeededCaptureScreen(model: model, seed: .reviewWithAI)),
            "capture.review.offline": AnyView(SeededCaptureScreen(model: model, seed: .reviewOffline)),
            // "Use AI" off with a router still configured: "Improve with AI" must show next to
            // "Made without AI" — the one reachable state that proves the button actually
            // appears (every other AI seed either has no router at all, or already ran the AI
            // pass automatically).
            "capture.review.aioff": AnyView(SeededCaptureScreen(model: model, seed: .reviewAIAvailableButOff)),
            // 40 tasks / 120 subtasks: proves the count header, per-task subtask collapse
            // ("+N više"), and LazyVStack list all hold up at real scale, not just the
            // 7-task demo note.
            "capture.review.big": AnyView(SeededCaptureScreen(model: model, seed: .reviewBig)),
            "capture.done": AnyView(SeededCaptureScreen(model: model, seed: .done)),
            // Feature F: the "From Apple Notes" picker's CONTENT exposed directly (popovers/
            // sheets can't be captured while presented, same reason list.viewoptions exposes
            // ListViewOptionsPopoverContent rather than the popover itself). Granted shows the
            // folder list; denied shows the one shared calm allow row.
            "capture.notes": AnyView(NotesPickerHost(model: model, denied: false)),
            "capture.notes.denied": AnyView(NotesPickerHost(model: model, denied: true)),
            // A layout bug visible live can stay invisible in every snapshot above, because
            // none of them render at the real overlay size — `capture`/`capture.review` above
            // are shot at whatever WxH the gate spec passes (720x560, historically), while the
            // actual host (AppShellView.swift:88-94) is a FIXED 520x520 box. These two match
            // that host's own frame + border + clip exactly, so what they show is what a real
            // window shows. Text size (Settings > Appearance) is exercised through the
            // harness's own `KRONOS_SNAPSHOT_PREFS=text=L` (SnapshotHarness.swift:11-18, applies
            // `DSScale` before the view is built) via gate-shots.mjs's `prefs=` option — these
            // two names need no size-specific variant of their own for that.
            "capture.paste.real": AnyView(RealOverlayHost(content: AnyView(SeededCaptureScreen(model: model, seed: .emptyPaste)))),
            "capture.review.real": AnyView(RealOverlayHost(content: AnyView(SeededCaptureScreen(model: model, seed: .reviewOffline)))),
            // A long title (CaptureFixtures.longTitleNote, ~90 chars) with a full set of
            // attributes, at the real host — proves the title wraps/ellipsizes and the
            // attributes line holds without either crowding the other.
            "capture.review.real.longtitle": AnyView(RealOverlayHost(content: AnyView(SeededCaptureScreen(model: model, seed: .reviewLongTitle)))),
        ]
    }
}

/// Mirrors `AppShellView.swift:88-94`'s Capture overlay host exactly (frame, border, clip) —
/// the only lines of that file this leaf owns. Kept as a tiny wrapper here rather than changing
/// what the two `capture.paste`/`capture.review` names above render, so every existing snapshot
/// name keeps its prior (looser) frame and only these two new names prove the real one.
private struct RealOverlayHost: View {
    let content: AnyView

    var body: some View {
        content
            .frame(width: Metrics.inspectorMax, height: Metrics.inspectorMax)
            .kBorder(Tok.hairline, radius: Radius.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Hosts `NotesPickerSheet`'s content at native size (not inside an actual `.sheet`), seeded
/// purely on `.onAppear` with a `FixtureNotesBridge` so the harness never shells out to
/// osascript. `denied` swaps in the same `.notAuthorised` state a real first-run/denied Mac
/// would show, through the bridge's own `errorToThrow` — no separate "denied" view exists;
/// this is the identical `NotesPickerSheet` reacting to a different fixture, matching how the
/// real app's two states differ only in what `model.notes` returns.
private struct NotesPickerHost: View {
    let model: AppModel
    let denied: Bool
    @State private var didSeed = false

    var body: some View {
        // `NotesPickerSheet` must not mount until `model.notes` is already the fixture: its
        // own `.task` fires on ITS appearance, which can race a sibling `.onAppear` set on
        // this wrapper (both are "did appear" callbacks with no ordering guarantee between
        // parent and child) — seeding first and only then constructing the sheet removes the
        // race entirely, same reasoning as `TriagedSnapshotHost`/`LinksSnapshotHost` gating on
        // `task != nil` above.
        Group {
            if didSeed {
                // Granted: opens straight into a folder with several notes (richer, more
                // representative state than an empty three-row folder list at this frame
                // size) via `initialFolder`; denied shows the folder LIST's own calm state,
                // since that is the first screen a user without Notes access actually sees.
                NotesPickerSheet(model: model, mode: .multi { _ in },
                                 initialFolder: denied ? nil : Self.meetingsFolder)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            model.notes = denied
                ? FixtureNotesBridge(errorToThrow: .notAuthorised)
                // A real Notes folder easily holds a dozen+ items; 15 rows here is a
                // realistic "well-used folder", not padding for its own sake, and fills
                // enough of the 720x560 gate frame to clear its non-empty-screen ink floor.
                // Varied `modifiedAt` (not all `Date()`) so the picker's per-row relative-date
                // label — added alongside this seed once the plain title-only row measured
                // short of the ink floor even at 15 rows — reads as real content, not a
                // repeated stamp.
                : FixtureNotesBridge(
                    folders: [NoteFolderInfo(id: "f1", name: "Kronos"), Self.meetingsFolder, NoteFolderInfo(id: "f3", name: "Personal")],
                    notesByFolder: [Self.meetingsFolder.name: [
                        NoteInfo(id: "n1", title: "Acme kickoff notes", modifiedAt: Date().addingTimeInterval(-3600)),
                        NoteInfo(id: "n2", title: "Weekly sync — Sep 15", modifiedAt: Date().addingTimeInterval(-86_400)),
                        NoteInfo(id: "n3", title: "Globex renewal call", modifiedAt: Date().addingTimeInterval(-2 * 86_400)),
                        NoteInfo(id: "n4", title: "Onboarding checklist review", modifiedAt: Date().addingTimeInterval(-3 * 86_400)),
                        NoteInfo(id: "n5", title: "1:1 — Alex", modifiedAt: Date().addingTimeInterval(-4 * 86_400)),
                        NoteInfo(id: "n6", title: "Vendor call — Initech", modifiedAt: Date().addingTimeInterval(-5 * 86_400)),
                        NoteInfo(id: "n7", title: "Q4 planning notes", modifiedAt: Date().addingTimeInterval(-6 * 86_400)),
                        NoteInfo(id: "n8", title: "Standup — action items", modifiedAt: Date().addingTimeInterval(-7 * 86_400)),
                        NoteInfo(id: "n9", title: "Client feedback — Globex", modifiedAt: Date().addingTimeInterval(-8 * 86_400)),
                        NoteInfo(id: "n10", title: "Retro — what went well", modifiedAt: Date().addingTimeInterval(-9 * 86_400)),
                        NoteInfo(id: "n11", title: "1:1 — Sam", modifiedAt: Date().addingTimeInterval(-10 * 86_400)),
                        NoteInfo(id: "n12", title: "Budget review — Q4", modifiedAt: Date().addingTimeInterval(-11 * 86_400)),
                        NoteInfo(id: "n13", title: "Hiring sync", modifiedAt: Date().addingTimeInterval(-12 * 86_400)),
                        NoteInfo(id: "n14", title: "Product roadmap notes", modifiedAt: Date().addingTimeInterval(-13 * 86_400)),
                        NoteInfo(id: "n15", title: "1:1 — Jordan", modifiedAt: Date().addingTimeInterval(-14 * 86_400)),
                    ]])
            didSeed = true
        }
    }

    private static let meetingsFolder = NoteFolderInfo(id: "f2", name: "Meetings")
}

/// Renders the real `CaptureScreen` after seeding the store and, for the AI variants, handing
/// it a scripted `AIRouting` fixture through `model.ai` — the same seam the app delegate uses
/// for the real router, so these snapshots exercise the shipped code path, not a stand-in.
private struct SeededCaptureScreen: View {
    enum Seed {
        case emptyPaste
        /// Router configured, still on the paste step — the ONLY seed that shows the "Use AI"
        /// switch + model name row, since every other AI seed below preloads into `.review`,
        /// past the paste step entirely.
        case pasteWithAI
        /// Notes pasted, deterministic rows already visible, the AI reply deliberately
        /// delayed past the harness's capture point — shows the "Improving with AI…" line.
        case aiPending
        case reviewWithAI
        case reviewOffline
        /// A router IS configured but the user's own switch (CapturePrefs.useAI) is off —
        /// `findTasks()` never calls it, so the review is offline even though AI is available:
        /// this is what makes "Improve with AI" show instead of staying hidden.
        case reviewAIAvailableButOff
        /// 40 tasks / 120 subtasks, offline (`CaptureFixtures.bigNote`) — see the count/collapse
        /// comment above.
        case reviewBig
        /// One ~90-char title with a full attribute set, offline (`CaptureFixtures.longTitleNote`).
        case reviewLongTitle
        case done
    }

    let model: AppModel
    let seed: Seed
    @State private var didSeed = false

    var body: some View {
        screen
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                plant()
            }
    }

    @ViewBuilder
    private var screen: some View {
        switch seed {
        case .emptyPaste, .pasteWithAI:
            CaptureScreen(model: model)
        case .aiPending, .reviewWithAI, .reviewOffline, .reviewAIAvailableButOff:
            CaptureScreen(model: model, preloadedText: CaptureFixtures.sampleNotes, preloadedStep: .review)
        case .reviewBig:
            CaptureScreen(model: model, preloadedText: CaptureFixtures.bigNote, preloadedStep: .review)
        case .reviewLongTitle:
            CaptureScreen(model: model, preloadedText: CaptureFixtures.longTitleNote, preloadedStep: .review)
        case .done:
            CaptureScreen(model: model, preloadedText: CaptureFixtures.sampleNotes, preloadedStep: .done)
        }
    }

    /// Every seed clears the harness's default 37-task import first (same pattern as
    /// ImpulsSnapshots) so the duplicate-detection and project-resolution demos are exact, not
    /// competing with unrelated seed data.
    private func plant() {
        for t in model.store.allTasks() { model.store.softDeleteNoUndo(t.id) }
        _ = model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[10].color.captureHexString,
                                      icon: "briefcase", area: nil)
        _ = model.store.createProject(name: "Globex", colorHex: KProjectPalette.swatches[6].color.captureHexString,
                                      icon: "globe", area: nil)
        model.store.createNoUndo(title: CaptureFixtures.existingOpenTitle, notes: "", project: nil,
                                 status: .todo, priority: .none, dueDay: nil)
        model.didMutate()

        switch seed {
        case .emptyPaste, .reviewOffline, .reviewBig, .reviewLongTitle:
            break   // AI off: model.ai stays nil throughout.
        case .pasteWithAI:
            model.ai = CaptureFixtures.sampleRouter()
        case .aiPending:
            model.ai = CaptureFixtures.sampleRouter(delay: .seconds(30))
        case .reviewWithAI, .done:
            model.ai = CaptureFixtures.sampleRouter()
        case .reviewAIAvailableButOff:
            model.ai = CaptureFixtures.sampleRouter()
            CapturePrefs.useAI = false   // must be set before CaptureScreen's own preload calls findTasks().
        }
    }
}
#endif
