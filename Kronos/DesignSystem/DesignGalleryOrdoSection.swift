// Kronos/DesignSystem/DesignGalleryOrdoSection.swift
// Gallery section: menu-bar Ordo — the label that sits in the menu bar, the popover
// content, and the 5s undo pill. Rev 3 amendment — replaces the floating Bar.
import SwiftUI

struct DesignGalleryOrdoSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "Menu bar Ordo")

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KMenuBarOrdoLabel — as it renders in the menu bar").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x4) {
                    menuBarChrome { KMenuBarOrdoLabel(title: "Nazvati klijenta oko ponude i ugovora") }
                    menuBarChrome { KMenuBarOrdoLabel(title: nil) }
                }
            }

            HStack(alignment: .top, spacing: Space.x6) {
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("KOrdoPopover — active task").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    KOrdoPopover(taskTitle: "Carousel za Acme", firstMove: "Otvoriti Affinity i staviti prvu fotku u predložak",
                                 remaining: 4, onComplete: {})
                        .kBorder(Tok.hairline, radius: Radius.popover)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.popover, style: .continuous))
                }
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("KOrdoPopover — empty queue").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    KOrdoPopover(taskTitle: nil, firstMove: nil, remaining: 0, onComplete: {})
                        .kBorder(Tok.hairline, radius: Radius.popover)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.popover, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KUndoPill — 5s draining ring").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KUndoPill(message: "Completed", onUndo: {}, onExpire: {})
            }
        }
    }

    /// A dark menu-bar-like strip so the template label reads in context.
    private func menuBarChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
                .foregroundStyle(Tok.textPrimary)
            Spacer().frame(width: Space.x4)
        }
        .frame(width: 260, height: 24)
        .background(Color.white.opacity(0.06))
        .kBorder(Tok.hairline, radius: 4)
    }
}
