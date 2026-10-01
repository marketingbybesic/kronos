// Open/save panels as a sheet on the key window, never `runModal()`: a modal panel centres
// on the MAIN display, so with Kronos or its Settings on the second screen the picker opened
// on the other monitor (live audit 30.09.). Every panel in the app goes through this.
import AppKit

extension NSSavePanel {
    func presentOnKeyWindow(_ onOK: @escaping (URL) -> Void) {
        let handle: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = self.url else { return }
            onOK(url)
        }
        if let window = NSApp.keyWindow { beginSheetModal(for: window, completionHandler: handle) }
        else { handle(runModal()) }
    }
}
