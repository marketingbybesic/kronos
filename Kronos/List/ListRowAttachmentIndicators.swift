// Kronos/List/ListRowAttachmentIndicators.swift
// The content-type icon cluster `ListRowView.swift` shows for a task's attached
// `ContextLink`s (file/folder/email/Apple Note/web), without opening the task. Split into its
// own file so ListRowView.swift stays under the project's 500-line budget (gate-files.mjs).
import SwiftUI
import KronosCore

extension ListRowView {
    /// Content-type glyphs (file/folder/email/Apple Note/web) for any `ContextLink` attached to
    /// this task — visible without opening it. One icon per distinct KIND present, not one per
    /// link, so three attached files still show a single file glyph; order is fixed (file/folder
    /// first — the most common drop — then email, note, web) so the cluster's shape never depends
    /// on attachment order. Reuses `ContextLinkActions.iconName` (Kronos/Detail/ContextLinkChips.swift),
    /// the SAME mapping the inspector's and a subtask's own attachment chips already draw, and
    /// `QuickAddContextChips.kindName` for the tooltip text — no new icon or string vocabulary
    /// invented here.
    @ViewBuilder var attachmentIndicators: some View {
        let kinds = attachmentKinds
        if !kinds.isEmpty {
            AttachmentIndicatorCluster(kinds: kinds, taskTitle: task.title)
        }
    }

    /// Distinct `ContextLink.Kind`s attached to `task`, in a fixed reading order.
    private var attachmentKinds: [ContextLink.Kind] {
        let order: [ContextLink.Kind] = [.file, .folder, .email, .appleNote, .web]
        let present = Set(ContextLink.findAll(in: task.notes).map(\.kind))
        return order.filter(present.contains)
    }
}

/// A brief scale+fade entrance the moment a task's attachment cluster first mounts — e.g. the
/// first file/mail/note dropped on a row that is already on screen. Self-contained `onAppear`
/// animation, the exact pattern `KPopoverEntrance` already uses (Kronos/DesignSystem/Border.swift),
/// reused here rather than adding a second entrance primitive to the design system. Under Reduce
/// Motion the cluster simply appears (`Motion.curve` collapses to a near-0 duration animation).
private struct AttachmentIndicatorCluster: View {
    let kinds: [ContextLink.Kind]
    let taskTitle: String
    @State private var isShown = false

    var body: some View {
        HStack(spacing: Space.x1) {
            ForEach(kinds, id: \.self) { kind in
                Icon(ContextLinkActions.iconName(kind), size: Metrics.iconXS)
                    .foregroundStyle(Tok.textTertiary)
                    .help(QuickAddContextChips.kindName(kind))
                    .uiTestAnchor("row.attachment." + kind.rawValue + "." + taskTitle)
            }
        }
        .scaleEffect(isShown ? 1 : 0.8, anchor: .leading)
        .opacity(isShown ? 1 : 0)
        .onAppear { withAnimation(Motion.curve(Motion.fast)) { isShown = true } }
    }
}
