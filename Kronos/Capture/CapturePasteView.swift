// Kronos/Capture/CapturePasteView.swift
// Step 1: one calm text area, a paste-from-clipboard convenience, ONE primary action, plus an
// Apple Notes source next to paste: "From Apple Notes" opens the shared folder -> note picker
// (multi-select) and appends every picked note's plain text to the same field paste would
// fill; "Pull from Notes inbox" does the same for the configured inbox folder
// (CoachSettings.notesInboxFolder) in one tap, no picker. Both funnel through the SAME review
// step as a paste — a note is never used to auto-create a task directly.
import SwiftUI
import AppKit
import KronosCore

struct CapturePasteView: View {
    @Bindable var capture: CaptureModel
    let model: AppModel
    @FocusState private var isFieldFocused: Bool
    @State private var isPickingNotes = false
    @State private var pickerInitialFolder: NoteFolderInfo?
    @State private var notesError: NotesError?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x5) {
            header
            aiRow
            // A fixed 280 pt `minHeight` plus the fallback footer's SECOND button row (wrapped
            // at Text size L) together taller than the card pushed the title off the top edge —
            // nothing above vertically compresses. `maxHeight: .infinity` lets the text area
            // give back space to its siblings instead of holding a floor that no longer fits;
            // the lower `minHeight` (still comfortably more than one line) keeps it from
            // collapsing to nothing.
            KTextArea(String(localized: "capture.paste.placeholder.examples"), text: $capture.noteText, minHeight: 120)
                .frame(maxHeight: .infinity)
                .focused($isFieldFocused)
            if let notesError {
                NotesAccessDeniedInline(error: notesError) { isPickingNotes = true }
            }
            footer
        }
        // Stepping Paste -> Review must not visibly jump sideways — the real Capture card is a
        // FIXED Metrics.inspectorMax (520x520) box (AppShellView.swift's
        // `.frame(width: Metrics.inspectorMax, height: Metrics.inspectorMax)`), so the same
        // content column for both steps needs the SAME horizontal inset, not a max-width (620
        // never actually bound inside a 520 box — dead, misleading constraint, removed).
        // Space.x5 matches CaptureReviewList's header/list/footer inset exactly, so the
        // left/right edges hold still across the step change.
        //
        // At Settings > Appearance > Text size L (especially with longer, non-English labels),
        // the footer's three `.fixedSize()` buttons summed wider than the 480 pt available
        // inside the 20 pt padding — a VStack sizes to its WIDEST child, so that one oversized
        // row inflated this whole column past 520, and `AppShellView`'s host frame then centred
        // + clipped the overflow on BOTH edges (title as well as the buttons). The fix is in
        // `footer` below (`ViewThatFits` degrades the row instead of reporting an oversized
        // ideal width) — a `.frame(maxWidth:)` here alone cannot cap a child's own measured
        // ideal size.
        .padding(.horizontal, Space.x5)
        .padding(.top, Space.x4)
        .padding(.bottom, Space.x3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isFieldFocused = true
            if let folder = capture.notesSourceFolder {
                capture.notesSourceFolder = nil
                pickerInitialFolder = folder
                isPickingNotes = true
            }
        }
        .sheet(isPresented: $isPickingNotes) {
            NotesPickerSheet(model: model, mode: .multi { notes in
                Task { await appendBodies(of: notes) }
            }, initialFolder: pickerInitialFolder)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: "capture.title"))
                .font(Typo.title)
                .foregroundStyle(Tok.textPrimary)
            Text(String(localized: "capture.subtitle"))
                .font(Typo.body)
                .foregroundStyle(Tok.textTertiary)
        }
    }

    /// A switch the user can actually SEE, not just the quiet status line the review step
    /// already showed. Three states: AI configured + on (switch, model name), AI configured +
    /// off (switch, quiet "off" note), AI not configured at all (no switch — nothing to flip —
    /// a one-line reason plus a button to Settings > AI, same pattern PermissionsWindow's own
    /// Claude-access row uses for "go configure it").
    @ViewBuilder
    private var aiRow: some View {
        if capture.isAIAvailable {
            KToggleRow(aiToggleLabel, isOn: $capture.useAI)
        } else {
            HStack(spacing: Space.x3) {
                Text(String(localized: "capture.ai.unavailable"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Button(String(localized: "capture.ai.open_settings")) {
                    guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil else { return }
                    NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil)
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
            }
        }
    }

    /// "Use AI (claude-sonnet-5)" when a model name is available; the plain label alone
    /// otherwise (a scripted/fixture router in tests carries no `modelID` this leaf can read —
    /// still AI, just without a name to show, never treated as AI being off).
    private var aiToggleLabel: String {
        guard let name = capture.aiModelName else { return String(localized: "capture.ai.use") }
        return String(format: String(localized: "capture.ai.use_named"), name)
    }

    /// Two rows, not one: three source buttons (paste, From Apple Notes, Pull inbox) plus the
    /// hint + primary action no longer fit one 620pt-wide row without wrapping once longer,
    /// non-English strings are in (the source buttons wrapped to two lines each, and the hint
    /// wrapped to three).
    ///
    /// `.fixedSize()` reports each button's full UNWRAPPED ideal width to its parent HStack
    /// regardless of available space — fine at Text size M, but at L (with longer labels) the
    /// three buttons' summed ideal width exceeds the 480 pt available inside the card's
    /// padding, which inflates the WHOLE VStack (see the root `.padding` comment above) rather
    /// than wrapping. `ViewThatFits` tries the one-row layout first and falls back to a
    /// 2-then-1 wrap the moment the row would overflow — proven at the real 520 pt host, Text
    /// size L, with longer labels.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            ViewThatFits(in: .horizontal) {
                sourceButtonsRow
                VStack(alignment: .leading, spacing: Space.x2) {
                    HStack(spacing: Space.x3) { pasteButton; notesButton }
                    inboxButton
                }
            }
            ViewThatFits(in: .horizontal) {
                findTasksRow
                // Fallback: the hint (decoration) drops before the primary action ever shrinks
                // or gets pushed off — the button alone, full width, always stays clickable and
                // fully labelled.
                HStack { Spacer(minLength: 0); findTasksButton }
            }
        }
    }

    private var sourceButtonsRow: some View {
        HStack(spacing: Space.x3) { pasteButton; notesButton; inboxButton; Spacer(minLength: 0) }
    }

    private var pasteButton: some View {
        Button(String(localized: "capture.paste.from_clipboard")) {
            if let clip = NSPasteboard.general.string(forType: .string) {
                capture.noteText = clip
            }
        }
        .kButton(.secondary).fixedSize()
    }

    private var notesButton: some View {
        Button(String(localized: "capture.notes.from_notes")) { pickerInitialFolder = nil; isPickingNotes = true }
            .kButton(.secondary).fixedSize()
    }

    private var inboxButton: some View {
        Button(String(localized: "capture.notes.pull_inbox")) { Task { await pullInbox() } }
            .kButton(.secondary).fixedSize()
    }

    private var findTasksRow: some View {
        HStack(spacing: Space.x3) {
            KKeyHintItem(["⌘", "⏎"], label: String(localized: "capture.hint.find_tasks"))
            Spacer(minLength: Space.x3)
            findTasksButton
        }
    }

    private var findTasksButton: some View {
        Button(String(localized: "capture.action.find_tasks")) {
            capture.findTasks()
        }
        .kButton(.primary).fixedSize()
        .disabled(capture.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Every picked note's plain text, separated by a blank line, appended to whatever is
    /// already in the field — matching the clipboard button's own "add to what's here"
    /// behaviour rather than silently replacing a draft already in progress.
    private func appendBodies(of notes: [NoteInfo]) async {
        var bodies: [String] = []
        for note in notes {
            if let body = try? await model.notes.body(ofNoteID: note.id), !body.isEmpty {
                bodies.append(body)
            }
        }
        guard !bodies.isEmpty else { return }
        let joined = bodies.joined(separator: "\n\n")
        capture.noteText = capture.noteText.isEmpty ? joined : capture.noteText + "\n\n" + joined
        notesError = nil
    }

    /// "Pull from Notes inbox": the one-tap path for the folder configured in Settings >
    /// Capture & Notes (CoachSettings.notesInboxFolder, default "Kronos") — same append
    /// behaviour as picking notes by hand, no picker sheet in the way.
    private func pullInbox() async {
        let folder = model.coach.settings.notesInboxFolder
        do {
            let notes = try await model.notes.notes(inFolder: folder)
            await appendBodies(of: notes)
        } catch let e as NotesError {
            notesError = e
        } catch {
            notesError = .unexpected("\(error)")
        }
    }
}
