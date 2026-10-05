// The Repeat popover exactly as it ships: the picker inside its inset, width and surface.
// InspectorRecurrenceSection presents this, and the snapshot harness renders this same view,
// so a screenshot of it is a screenshot of the real popover.
import SwiftUI
import KronosCore

struct InspectorRecurrencePopover: View {
    /// Space between the popover edge and the picker's content, on every side.
    static let inset = Space.x4
    static let width: CGFloat = 288

    let rule: RecurrenceRule?
    let locale: String
    let onChange: (RecurrenceRule?) -> Void

    var body: some View {
        InspectorRecurrenceEditor(rule: rule, locale: locale, onChange: onChange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .uiTestAnchor("recurrence.popover.content")
            .padding(Self.inset)
            .frame(width: Self.width)
            .background(Tok.overlay, ignoresSafeAreaEdges: .all)
            .uiTestAnchor("recurrence.popover.root")
    }
}
