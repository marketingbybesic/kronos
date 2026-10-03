// Kronos/QuickAdd/QuickAddContextChips.swift
// The context the panel picked up from the app it was opened over, as removable chips (a web
// page, a mail message, files, an Apple Note), plus the one chip that asks macOS for the
// Automation permission when the answer is not known yet. A submit attaches the chips to the
// first task (QuickAddCreate `links:`); the ✕ drops a chip.
import SwiftUI
import KronosCore

struct QuickAddContextChips: View {
    let context: QuickAddContextState

    var body: some View {
        if !context.links.isEmpty || context.consent != nil {
            KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
                ForEach(context.links, id: \.reference) { link in
                    let kind = Self.anchorName(link.kind)
                    KChip(link.displayName, trailing: .clear, onTap: {}, onTrailingTap: { context.remove(link) },
                          trailingAnchorID: "quickadd.context.\(kind).remove") {
                        Icon(Self.iconName(link.kind), size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .help(link.displayName)
                    .accessibilityHint(Self.kindName(link.kind))
                    .uiTestAnchor("quickadd.context.\(kind)")
                }
                if let consent = context.consent {
                    KChip(Self.consentTitle(consent, appName: context.front?.name ?? ""),
                          onTap: { context.askConsent() }) {
                        Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                    }
                    .help(String(localized: "quickadd.context.consent.help"))
                    .uiTestAnchor("quickadd.context.consent")
                }
            }
            .animation(Motion.hover, value: context.links.map(\.reference))
        }
    }

    static func anchorName(_ kind: ContextLink.Kind) -> String {
        switch kind {
        case .web: return "web"
        case .email: return "email"
        case .file: return "file"
        case .folder: return "folder"
        case .appleNote: return "note"
        }
    }

    static func iconName(_ kind: ContextLink.Kind) -> String {
        switch kind {
        case .web: return "globe"
        case .email: return "mail"
        case .file: return "receipt"
        case .folder: return "folder"
        case .appleNote: return "receipt"
        }
    }

    /// What VoiceOver adds after the chip's title.
    static func kindName(_ kind: ContextLink.Kind) -> String {
        switch kind {
        case .web: return String(localized: "quickadd.context.a11y.web")
        case .email: return String(localized: "quickadd.context.a11y.email")
        case .file: return String(localized: "quickadd.context.a11y.file")
        case .folder: return String(localized: "quickadd.context.a11y.folder")
        case .appleNote: return String(localized: "quickadd.context.a11y.note")
        }
    }

    /// "Link the Safari tab", "Link the selected email" ... A browser carries its own name.
    static func consentTitle(_ source: QuickAddContextSource, appName: String) -> String {
        switch source {
        case .safari, .chromium:
            return String(format: String(localized: "quickadd.context.consent.browser"), appName)
        case .mail: return String(localized: "quickadd.context.consent.mail")
        case .finder: return String(localized: "quickadd.context.consent.finder")
        case .notes: return String(localized: "quickadd.context.consent.notes")
        case .other: return String(format: String(localized: "quickadd.context.consent.browser"), appName)
        }
    }
}
