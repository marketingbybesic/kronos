// Kronos/Detail/InspectorCoachSection.swift — the triage fill line + Re-triage control, and
// the Apple Note link + context-link chips.
//
// Triage: `AutoTriage.live` (the running service) is nil during a
// snapshot run, so `inspector.triaged`'s fixture renders this view with an injected
// `TriageFillDisplay` rather than through the live service. The real screen always reads the
// live service and passes nil here.
//
// Links: a task carries at most one `NoteLink` (`notes://`) and at most one `ContextLink`
// (`link://`) in its notes text (KronosCore/Coach/AppleNotesBridge.swift) — both encoded as
// one line each, independent of each other and of the human-readable notes text around them.
import SwiftUI
import AppKit
import KronosCore

/// `NoteLink`/`ContextLink` store their one-line references INSIDE the task's notes text
/// (their own doc comments: "encoded as one `link://`/`notes://` line... alongside... the
/// human-readable notes text"). The notes editor must never show that raw plumbing
/// (`notes://fixture-id`, `link://web|title|https://...`) as if it were something the user
/// typed, so every read/write of the VISIBLE notes text in this file's screens goes through
/// these two helpers rather than touching `task.notes` directly.
enum InspectorNotesText {
    /// The human-readable portion only — every `notes://`/`link://` line removed.
    static func visible(_ notes: String) -> String {
        notes.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("notes://") && !trimmed.hasPrefix("link://")
            }
            .joined(separator: "\n")
    }

    /// Rebuilds the full notes text from an edited VISIBLE draft plus the original text's own
    /// control lines (order preserved, never re-derived) — so editing the visible notes can
    /// never drop or corrupt a note/context link that was not touched.
    static func merging(visibleDraft: String, controlLinesFrom original: String) -> String {
        let controlLines = original.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("notes://") || trimmed.hasPrefix("link://")
        }
        let trimmedDraft = visibleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !controlLines.isEmpty else { return trimmedDraft }
        let lines = trimmedDraft.isEmpty ? controlLines : [trimmedDraft] + controlLines
        return lines.joined(separator: "\n")
    }

    /// A dropped text with no Notes-title match falls back to appending it to the task's
    /// VISIBLE notes text — that is what the editor did before a drop overlay started
    /// catching text drags, and dropping text from Safari must keep working. Appends after
    /// the existing visible text (own paragraph, blank line between), control lines untouched.
    static func appendingVisibleText(_ text: String, to notesText: String) -> String {
        let existingVisible = visible(notesText)
        let merged = existingVisible.isEmpty ? text : existingVisible + "\n\n" + text
        return merging(visibleDraft: merged, controlLinesFrom: notesText)
    }
}

/// What the triage-filled line needs to render — either read from the live `AutoTriage.Fill`
/// or supplied directly by a snapshot fixture (see file doc comment above).
struct TriageFillDisplay: Equatable {
    let fields: [TriageFieldKind]
    let reason: String?
    /// Whether `reason` is one of NeighbourTriage's fixed English shapes (localised at the
    /// render site) or arbitrary AI text already in the task's language. Defaults true so the
    /// snapshot fixture (DetailSnapshots.swift, which always uses the fixed
    /// "like N similar X tasks" shape) keeps working without every call site changing.
    var isNeighbourSourced: Bool = true
}

// MARK: - Triage filled line

struct InspectorTriageFillRow: View {
    let model: AppModel
    let task: KTask
    /// Snapshot-only override — see file doc comment. Always nil on the real screen.
    var previewFill: TriageFillDisplay??

    private var fill: TriageFillDisplay? {
        if let previewFill { return previewFill }
        // The service is not observable: reading the model's change counter makes this row
        // re-render whenever the store changes (a Discard, a fresh fill), so the line never
        // outlives the record it was drawn from.
        _ = model.version
        guard let f = AutoTriage.live?.lastFill[task.id] else { return nil }
        return TriageFillDisplay(fields: f.fields, reason: f.reason, isNeighbourSourced: f.isNeighbourSourced)
    }

    var body: some View {
        if let fill, !fill.fields.isEmpty {
            HStack(spacing: Space.x2) {
                Icon("sparkles", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                Text(filledText(fill))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.x2)
                // Frame and contentShape live INSIDE the label: after `.buttonStyle(.plain)` they
                // would be a dead wrapper and only the text's own pixels could be pressed.
                Button(action: discard) {
                    Text(String(localized: "triage.diff.discard"))
                        .font(Typo.metaStrong)
                        .foregroundStyle(Tok.textPrimary)
                        .frame(minHeight: Metrics.minHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .uiTestAnchor("inspector.triage.discard")
            }
            .padding(.top, Space.x1)
        }
    }

    /// "Filled: priority, effort — like 3 similar Acme tasks." Field names come from the
    /// same catalog keys the property rows already use, joined with a plain comma (never a
    /// second sentence) so the line stays the one quiet line the brief asks for.
    private func filledText(_ fill: TriageFillDisplay) -> String {
        let names = fill.fields.map(fieldName).joined(separator: ", ")
        let base = String(format: String(localized: "triage.filled.fields"), names)
        guard let reason = fill.reason, !reason.isEmpty else { return base }
        return base + " — " + localizedNeighbourReason(reason, isNeighbourSourced: fill.isNeighbourSourced)
    }

    private func fieldName(_ field: TriageFieldKind) -> String {
        switch field {
        case .project: String(localized: "detail.section.project")
        case .priority: String(localized: "viewoptions.field.priority")
        case .due: String(localized: "viewoptions.field.deadline")
        case .depth: String(localized: "detail.depth")
        case .estimateMinutes: String(localized: "detail.estimate.short")
        case .energyKind: String(localized: "triage.field.energy")
        case .firstMove: String(localized: "detail.firstmove")
        case .labels: String(localized: "detail.section.labels")
        case .effort: String(localized: "viewoptions.field.effort")
        }
    }

    /// Clears exactly the fields the last triage filled (the store keeps that record), one undo
    /// step; anything edited since, the title included, stays.
    private func discard() {
        model.store.revertTriageFill(task: task.id)
        // Drop the record before the refresh: the line renders from it, so refreshing first would
        // leave "Filled: ..." on screen until the next unrelated change.
        AutoTriage.live?.clearFill(task.id)
        model.didMutate()
    }
}

// MARK: - Re-triage control

/// Quiet text control next to the triage-filled line (or on its own when nothing has been
/// filled yet): fill-only by default, Option-click overwrites. Disabled with no live
/// `AutoTriage` service (a snapshot run, or AI/triage genuinely unavailable) — re-triage is a
/// live action, never something this leaf re-implements from Core primitives directly, so the
/// service being absent means the control has nothing to call, not a fallback path to invent.
struct InspectorRetriageControl: View {
    let model: AppModel
    let task: KTask
    @State private var isHovering = false

    var body: some View {
        // Root cause of a "must click 2-3 times" bug found in live UI testing: frame +
        // contentShape chained AFTER `.buttonStyle(.plain)` is a dead wrapper — only the
        // label's opaque pixels are pressable. Moved inside the label closure.
        Button(action: retriage) {
            HStack(spacing: Space.x1) {
                Icon("refresh", size: Metrics.iconXS)
                Text(String(localized: "triage.retriage"))
            }
            .font(Typo.meta)
            .foregroundStyle(isHovering ? Tok.textPrimary : Tok.textTertiary)
            .frame(height: Metrics.minHit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
        .disabled(AutoTriage.live == nil)
        .kTooltip(String(localized: "detail.help.resort"))
    }

    private func retriage() {
        let overwrite = NSEvent.modifierFlags.contains(.option)
        AutoTriage.live?.triage(task.id, fillOnly: !overwrite)
    }
}

// MARK: - Apple Note link

/// "Link Apple note" / linked-state row: shows the linked note's title, "Open note" and
/// Unlink when a `NoteLink` is present in the task's notes text, else a single "Link Apple
/// note" control that opens the folder → note picker sheet. Missing Notes access renders the
/// SAME calm allow row `CaptureNotesSourceView` uses (Kronos/Capture/CaptureNotesPicker.swift)
/// — one shared component, not two copies of the same state.
struct InspectorNoteLinkRow: View {
    let model: AppModel
    let task: KTask
    /// Set by `InspectorScreen` in response to `kronosLinkNoteRequested` (the palette's "Link
    /// Apple note to selected task" command) — opens the picker exactly as if the user had
    /// clicked "Link Apple note" themselves, then resets itself.
    @Binding var requestOpen: Bool
    @State private var isPicking = false
    @State private var linkedTitle: String?
    /// First two lines of the note's body, shown as a summary — kept separate from
    /// `linkedTitle` (line 1 alone) because the unlinked/loading fallback still needs a bare
    /// title with no summary underneath.
    @State private var linkedSummaryLines: [String] = []
    @State private var loadError: NotesError?

    private var linkedNoteID: String? { NoteLink.find(in: task.notes) }

    var body: some View {
        Group {
            if linkedNoteID != nil {
                // Linked state is its own card (art-direction.md: borders stay only for
                // true text surfaces and the first-move panel) rather than squeezed into
                // KPropertyRow's fixed single-line slot, so the 2-line summary has room.
                // This block breaks out of the property list's `spacing: 0` line-item rhythm
                // it sits inside (InspectorScreen.swift), so it carries its own top gap — the
                // section caption previously sat flush against the hairline above it, unlike
                // every other section caption in the pane.
                VStack(alignment: .leading, spacing: Space.x2) {
                    InspectorSectionCaption(String(localized: "detail.section.notelink"))
                    content
                }
                .padding(.top, Space.x4)
            } else {
                KPropertyRow(String(localized: "detail.section.notelink")) { content }
            }
        }
        .task(id: task.id) { await loadTitle() }
        .onChange(of: requestOpen) { _, new in
            guard new else { return }
            isPicking = true
            requestOpen = false
        }
        .sheet(isPresented: $isPicking) {
            NotesPickerSheet(model: model, mode: .single { note, _ in
                link(noteID: note.id, title: note.title)
            })
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError, linkedNoteID == nil {
            NotesAccessDeniedInline(error: loadError) { isPicking = true }
        } else if let linkedNoteID {
            // Compact card: title, first 2 lines as a summary, "Open in Notes". The title
            // truncates first (`layoutPriority` + `lineLimit`) and both actions are
            // `.fixedSize()` so neither ever wraps internally — a longer translation of "Open
            // note" wrapped to two lines and pushed the title down before this fix.
            KPanel {
                VStack(alignment: .leading, spacing: Space.x1) {
                    HStack(spacing: Space.x2) {
                        Icon("note.text", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                        Text(linkedTitle ?? linkedNoteID)
                            .font(Typo.row).foregroundStyle(Tok.textPrimary).lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: Space.x2)
                        Button { unlink() } label: { Text(String(localized: "detail.calendar.unlink")).kHitTarget() }
                            .buttonStyle(.plain).font(Typo.meta).foregroundStyle(Tok.textTertiary).fixedSize()
                    }
                    if !linkedSummaryLines.isEmpty {
                        Text(linkedSummaryLines.joined(separator: "\n"))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Metrics.iconS + Space.x2)
                    }
                    Button { openNote(linkedNoteID) } label: { Text(String(localized: "detail.notelink.open")).kHitTarget() }
                        .buttonStyle(.plain).font(Typo.meta).foregroundStyle(Tok.textSecondary)
                        .padding(.leading, Metrics.iconS + Space.x2)
                        .padding(.top, Space.x1)
                        .uiTestAnchor("inspector.notelink.open")
                }
            }
        } else {
            // Drag-and-drop for linking a note never worked reliably; this control existed as
            // a plain-text `.buttonStyle(.plain)` row indistinguishable from a label, now a
            // real bordered button with a glyph, same idiom as every other affordance-carrying
            // control in the app (KButton.swift).
            Button {
                isPicking = true
            } label: {
                HStack(spacing: Space.x2) {
                    Icon("note.text", size: Metrics.iconS)
                    Text(String(localized: "detail.notelink.add"))
                }
            }
            .kButton(.secondary, size: .compact)
            .uiTestAnchor("inspector.notelink.add")
        }
    }

    private func loadTitle() async {
        guard let id = linkedNoteID else { linkedTitle = nil; linkedSummaryLines = []; return }
        do {
            let body = try await model.notes.body(ofNoteID: id)
            let lines = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            linkedTitle = lines.first ?? id
            // Summary = the 2 lines AFTER the title (the title is the note's own first
            // line — repeating it as line 1 of its own summary would just echo the title
            // the card already shows above).
            linkedSummaryLines = Array(lines.dropFirst().prefix(2))
            loadError = nil
        } catch let e as NotesError {
            loadError = e
        } catch { /* non-Notes errors leave the last known title on screen */ }
    }

    private func link(noteID: String, title: String) {
        Self.link(model: model, task: task, noteID: noteID, title: title)
        linkedTitle = title
        linkedSummaryLines = []
        isPicking = false
    }

    /// The one store write for linking a note, shared by this row's picker and the NOTES-header
    /// button (the Apple Notes drag target that used to call this too was removed: it never
    /// received a drag). Only the local `@State` refresh above is specific to this row.
    static func link(model: AppModel, task: KTask, noteID: String, title: String) {
        model.store.update(task.id) { $0.notes = NoteLink.appending(noteID, to: $0.notes) }
        model.didMutate()
    }

    private func unlink() {
        model.store.update(task.id) { t in
            t.notes = t.notes.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("notes://") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        model.didMutate()
        linkedTitle = nil
        linkedSummaryLines = []
    }

    private func openNote(_ id: String) {
        // `id of note` is an `x-coredata://` URL, not the `applenotes://showNote?identifier=`
        // UUID — no documented transform between the two — so this goes through the bridge's
        // own AppleScript `show note id` rather than constructing a URL. User-initiated (this
        // is a button tap), so it is fine to bring Notes forward and to prompt for Automation
        // access on a first use.
        Task {
            do {
                try await model.notes.open(noteID: id)
            } catch {
                // Any failure (denied access, note deleted) falls back to just bringing Notes
                // forward — same calm "never crash" rule the old comment described.
                openNotesApp()
            }
        }
    }
}

/// Opens Notes.app by bundle identifier — `NSWorkspace.launchApplication(_:)` (by name) is
/// deprecated; this is the one place both `InspectorNoteLinkRow` and
/// `InspectorContextLinksRow` reach for "just bring Notes to the front".
private func openNotesApp() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return }
    NSWorkspace.shared.open(url)
}

// Context links (feature M): Kronos/Detail/ContextLinkChips.swift.
