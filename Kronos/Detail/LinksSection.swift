// LinksSection: the attachments of a task OR a subtask, one section for both. One "+" menu
// (File…, Web link…, Apple note…), one chip per link (ContextLinkChip: click opens or reveals,
// right-click has Open / Show in Finder / Copy link / Rename / Remove). A URL pasted with
// Cmd-V while the inspector (not a text field) has focus becomes a web chip. Nothing empty or
// malformed is ever stored; adding what is already attached, or renaming to the same name,
// changes nothing and pushes no undo step.
import SwiftUI
import AppKit
import KronosCore

/// Every write to a task's or subtask's `link://` lines from the inspector.
@MainActor
enum LinkEditing {
    static func notes(of target: AttachmentTarget, model: AppModel) -> String {
        switch target {
        case .task(let id): model.store.task(id)?.notes ?? ""
        case .subtask(let s): s.notes
        }
    }

    /// Attaches `link`. False (and nothing written) for an empty reference, or when the same
    /// kind + reference is already attached.
    @discardableResult
    static func add(_ link: ContextLink, to target: AttachmentTarget, model: AppModel) -> Bool {
        let reference = link.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return false }
        let name = link.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = ContextLink(kind: link.kind, reference: reference, displayName: name.isEmpty ? reference : name, origin: link.origin)
        let current = notes(of: target, model: model)
        let next = clean.appending(to: current)
        guard next != current else { return false }
        write(next, to: target, model: model)
        return true
    }

    /// Changes the label of `link` in place (same position, same reference). Blank or unchanged
    /// names are ignored.
    static func rename(_ link: ContextLink, to newName: String, on target: AttachmentTarget, model: AppModel) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != link.displayName else { return }
        let renamed = ContextLink(kind: link.kind, reference: link.reference, displayName: name, origin: link.origin)
        let current = notes(of: target, model: model)
        var changed = false
        let lines = current.components(separatedBy: "\n").map { line -> String in
            guard !changed, let found = ContextLink.find(in: line),
                  found.kind == link.kind, found.reference == link.reference else { return line }
            changed = true
            return renamed.encodedLine
        }
        guard changed else { return }
        write(lines.joined(separator: "\n"), to: target, model: model)
    }

    /// A file or folder as a link (security-scoped bookmark, same shape a Finder drop stores).
    static func fileLink(for url: URL) -> ContextLink {
        let fields = FileDropPasteboard.fields(for: url)
        return ContextLink(kind: fields.isDirectory ? .folder : .file, reference: fields.reference, displayName: fields.displayName)
    }

    static func webLink(_ web: LinkInput.Web, name: String = "") -> ContextLink {
        let custom = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContextLink(kind: .web, reference: web.reference, displayName: custom.isEmpty ? web.label : custom)
    }

    private static func write(_ notes: String, to target: AttachmentTarget, model: AppModel) {
        switch target {
        case .task(let id): model.store.update(id) { $0.notes = notes }
        case .subtask(let s): model.store.updateSubtaskNotes(s.id, notes: notes)
        }
        model.didMutate()
    }
}

struct LinksSection: View {
    let model: AppModel
    let target: AttachmentTarget
    @State private var isWebSheetOpen = false
    @State private var isNotePickerOpen = false
    /// Read once when the section is created (see InspectorDropHint).
    @State private var dropHintOwed = InspectorDropHint.shouldShow()

    private var links: [ContextLink] {
        ContextLink.findAll(in: LinkEditing.notes(of: target, model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                InspectorSectionCaption(String(localized: "detail.section.links"))
                Spacer()
                addMenu
            }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: Space.x1) {
                    ForEach(links, id: \.encodedLine) { link in
                        ForeignAwareChip(link: link, target: target, model: model)
                    }
                }
            } else if dropHintOwed, case .task = target {
                Text(String(localized: "detail.drophint"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .onAppear { InspectorDropHint.markSeen() }
                    .uiTestAnchor("inspector.drophint")
            }
        }
        .sheet(isPresented: $isWebSheetOpen) {
            WebLinkSheet { web, name in LinkEditing.add(LinkEditing.webLink(web, name: name), to: target, model: model) }
        }
        .sheet(isPresented: $isNotePickerOpen) {
            NotesPickerSheet(model: model, mode: .single { note, _ in
                LinkEditing.add(ContextLink(kind: .appleNote, reference: note.id, displayName: note.title), to: target, model: model)
            })
        }
    }

    private var addMenu: some View {
        Menu {
            Button(String(localized: "detail.links.add.file")) { chooseFile() }
            Button(String(localized: "detail.links.add.web")) { isWebSheetOpen = true }
            Button(String(localized: "detail.links.add.note")) {
                // A task keeps its single linked-note card; the shell hosts that picker.
                if case .task = target { model.noteLinkPickerOpen = true } else { isNotePickerOpen = true }
            }
        } label: {
            Icon("plus", size: Metrics.iconS)
                .foregroundStyle(Tok.textTertiary)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "detail.links.add.accessibility"))
        .uiTestAnchor("inspector.links.add")
    }

    /// Not sandboxed (ENABLE_APP_SANDBOX: NO), so a picked or typed path needs no extra grant;
    /// the panel's own Cmd-Shift-G is the typed-path field. The stored bookmark is still
    /// security-scoped, like every other file link.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "detail.links.add.file.prompt")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { LinkEditing.add(LinkEditing.fileLink(for: url), to: target, model: model) }
    }
}

/// A link made on another device is dimmed and says so ("on MacBook Pro"): its bookmark or
/// Mail/Notes id only resolves there. Still removable and renamable. Web links and links with
/// no recorded origin look and behave as before.
struct ForeignAwareChip: View {
    let link: ContextLink
    let target: AttachmentTarget
    let model: AppModel
    /// The small chip of a subtask row.
    var compact = false

    var body: some View {
        if let device = link.foreignDeviceName(on: DeviceOrigin.current) {
            let whereFrom = String(format: String(localized: "detail.links.foreign"), device)
            HStack(spacing: Space.x2) {
                // The chip keeps its name; in a narrow subtask row the device line gives way first
                // (the whole line stays in the help tag).
                ContextLinkChip(link: link, target: target, model: model, compact: compact)
                    .opacity(0.6)
                    .layoutPriority(1)
                    .accessibilityHint(whereFrom)
                Text(whereFrom)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(1)
            }
            .help(whereFrom)
            .uiTestAnchor(compact ? "inspector.subtask.contextlink.foreign" : "inspector.contextlink.foreign")
        } else {
            ContextLinkChip(link: link, target: target, model: model, compact: compact)
        }
    }
}

/// "Web link…": paste or type the address, optionally name it; Add stays disabled until the
/// address is a real web link, so an empty or malformed reference can never reach the store.
struct WebLinkSheet: View {
    let onAdd: (LinkInput.Web, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""

    private var parsed: LinkInput.Web? { LinkInput.web(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            InspectorSectionCaption(String(localized: "detail.links.web.title"))
            KTextField(String(localized: "detail.links.web.url.placeholder"), text: $address, leading: "globe", autofocus: true)
                .onSubmit(add)
                .uiTestAnchor("inspector.links.web.url")
            KTextField(parsed?.label ?? String(localized: "detail.links.web.name.placeholder"), text: $name)
                .onSubmit(add)
            if !address.isEmpty, parsed == nil {
                Text(String(localized: "detail.links.web.invalid"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            HStack(spacing: Space.x2) {
                Spacer()
                Button(String(localized: "common.cancel")) { dismiss() }
                    .kButton(.ghost, size: .compact)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "common.add")) { add() }
                    .kButton(.primary, size: .compact)
                    .disabled(parsed == nil)
                    .uiTestAnchor("inspector.links.web.add")
            }
        }
        .padding(Space.x4)
        .frame(width: 340)
        .background(Tok.overlay)
        .onAppear {
            if let text = NSPasteboard.general.string(forType: .string), let url = LinkInput.pastedURL(text) { address = url.reference }
        }
    }

    private func add() {
        guard let parsed else { return }
        onAdd(parsed, name)
        dismiss()
    }
}

extension View {
    /// Cmd-V on the inspector (focus anywhere in it EXCEPT a text field: there the paste
    /// belongs to the text) with a URL on the clipboard attaches it as a web chip.
    /// A local key monitor, not `onKeyPress`: the Edit > Paste menu item claims Cmd-V before a
    /// SwiftUI key handler sees it. The monitor lives only while the inspector is on screen, acts
    /// only when its own window is key, and leaves the event alone whenever a text view is
    /// editing, the clipboard holds no URL, or any other modifier is down.
    func kPasteURLAsLink(model: AppModel, target: AttachmentTarget) -> some View {
        modifier(PasteURLMonitor(model: model, target: target))
    }
}

private final class PasteURLHost: ObservableObject {
    weak var window: NSWindow?
    var monitor: Any?
}

private struct PasteURLMonitor: ViewModifier {
    let model: AppModel
    let target: AttachmentTarget
    @StateObject private var host = PasteURLHost()

    func body(content: Content) -> some View {
        content
            .background(PasteURLWindowReader { host.window = $0 })
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        remove()
        let host = host, model = model, target = target
        host.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard mods == .command, event.keyCode == 9,   // physical V key, any keyboard layout
                  let win = host.window, event.window === win, win.isKeyWindow,
                  !(win.firstResponder is NSTextView),
                  let text = NSPasteboard.general.string(forType: .string),
                  let web = LinkInput.pastedURL(text) else { return event }
            let added = MainActor.assumeIsolated { LinkEditing.add(LinkEditing.webLink(web), to: target, model: model) }
            return added ? nil : event
        }
    }

    private func remove() {
        if let m = host.monitor { NSEvent.removeMonitor(m) }
        host.monitor = nil
    }
}

private struct PasteURLWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Probe(onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void
        init(_ onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow(window) }
    }
}
