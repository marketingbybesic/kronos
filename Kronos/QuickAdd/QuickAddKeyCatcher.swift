// Kronos/QuickAdd/QuickAddKeyCatcher.swift
// The panel's key handling (Return / Option-Return / Tab / arrows / Esc / Backspace) and the
// switching-off of macOS smart text substitution live in Kronos/Shared/EntryField/EntryKeyBridge.swift
// now. What stays here is the one lookup the live UI test uses to reach the panel's text view.
import AppKit

extension NSView {
    /// Depth-first search for the first `NSTextView` descendant.
    var qaFirstTextView: NSTextView? {
        if let textView = self as? NSTextView { return textView }
        for sub in subviews {
            if let found = sub.qaFirstTextView { return found }
        }
        return nil
    }
}
