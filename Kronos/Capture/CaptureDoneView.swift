// Kronos/Capture/CaptureDoneView.swift
// Step 3: a calm confirmation with the same 5 s inline undo affordance the rest of the app
// uses (KUndoPill), then closes. Undo here reverses the whole batch in one Cmd-Z, since
// `createMany` registers exactly one undo step regardless of row count.
import SwiftUI
import KronosCore

struct CaptureDoneView: View {
    let model: AppModel
    let count: Int
    let onFinished: () -> Void

    var body: some View {
        KPanel(padding: Space.x8) {
            VStack(spacing: Space.x4) {
                Icon("check-square", size: Metrics.iconXL + 12)
                    .foregroundStyle(Tok.textSecondary)
                VStack(spacing: Space.x1) {
                    Text(String(format: String(localized: "capture.done.message"), count))
                        .font(Typo.title)
                        .foregroundStyle(Tok.textPrimary)
                    Text(String(localized: "capture.done.subtitle"))
                        .font(Typo.body)
                        .foregroundStyle(Tok.textTertiary)
                }
                KHairline()
                KUndoPill(message: String(localized: "capture.done.undo_hint"),
                          onUndo: { model.store.undo(); model.didMutate(); onFinished() },
                          onExpire: onFinished)
            }
            .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
