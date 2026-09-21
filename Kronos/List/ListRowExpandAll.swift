// The E key (HotkeyRegistry "list.expandall") opens or closes every subtask list at once.
// Each row keeps its own expanded state; this modifier lets the list-wide key drive it.
import SwiftUI

extension View {
    func followsExpandAll(_ isExpanded: Binding<Bool>, hasSubtasks: Bool) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .kronosExpandAllSubtasks)) { note in
            guard hasSubtasks, let open = note.object as? Bool else { return }
            withAnimation(Motion.curve(Motion.fast)) { isExpanded.wrappedValue = open }
        }
    }
}
