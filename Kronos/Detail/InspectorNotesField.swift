// The notes editor: at least three lines tall, then it grows with its text so the whole note is
// always visible inside the inspector's own scroll (a fixed-height editor scrolled a second time
// inside the first). A hidden copy of the text sizes the stack; the editor fills it.
import SwiftUI

struct InspectorNotesField: View {
    let placeholder: String
    @Binding var text: String

    private var minHeight: CGFloat { Metrics.controlRegular * 3 }

    var body: some View {
        ZStack(alignment: .top) {
            // Same insets as KTextArea's placeholder (the TextEditor's text sits there), plus a
            // trailing newline so a caret on a fresh last line has room.
            Text(text + "\n")
                .font(Typo.body)
                .padding(.horizontal, Space.x4)
                .padding(.vertical, Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            KTextArea(placeholder, text: $text, minHeight: minHeight)
        }
        .uiTestAnchor("inspector.notes.field")
    }
}
