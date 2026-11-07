// Kronos/List/ListEmptyStates.swift
// What an empty list says: what the list is for (one line) and, where another list is the
// answer, one button to it. Lists that take tasks offer none: the New task row above is already
// focused.
import SwiftUI
import KronosCore

struct ListEmptyState: View {
    @Bindable var model: AppModel

    var body: some View {
        let content = Self.content(for: model.scope)
        KEmptyState(icon: content.icon, title: content.title, message: content.purpose,
                    action: content.next.map { n in KEmptyState.Action(title: n.title) { show(n.scope) } })
            .uiTestAnchor("list.empty")
    }

    struct NextStep: Equatable {
        let scope: ListScope
        
        var title: String {
            switch scope {
            case .inbox:
                return String(localized: "list.empty.action.inbox")
            case .all:
                return String(localized: "list.empty.action.all")
            default:
                return String(localized: "list.empty.action.inbox")
            }
        }
    }

    struct Content {
        let icon: String
        let title: String
        let purpose: String
        let next: NextStep?
    }

    static func content(for scope: ListScope) -> Content {
        switch scope {
        case .inbox:
            return Content(icon: "inbox", title: String(localized: "empty.inbox.body"),
                           purpose: String(localized: "list.empty.inbox.purpose"), next: nil)
        case .today:
            return Content(icon: "sun", title: String(localized: "today.clear.title"),
                           purpose: String(localized: "today.clear.hint"), next: nil)
        case .next7:
            return Content(icon: "calendar-days", title: String(localized: "empty.next7.body"),
                           purpose: String(localized: "list.empty.next7.purpose"),
                           next: NextStep(scope: .inbox))
        case .waiting:
            return Content(icon: "hourglass", title: String(localized: "list.empty.waiting.title"),
                           purpose: String(localized: "list.empty.waiting.purpose"),
                           next: NextStep(scope: .all))
        case .someday:
            return Content(icon: "archive", title: String(localized: "list.empty.someday.title"),
                           purpose: String(localized: "list.empty.someday.purpose"),
                           next: NextStep(scope: .inbox))
        case .project, .area:
            return Content(icon: "folder", title: String(localized: "list.empty.project.title"),
                           purpose: String(localized: "list.empty.project.purpose"), next: nil)
        case .all, .savedView:
            return Content(icon: "list-ordered", title: String(localized: "empty.view.body"),
                           purpose: String(localized: "list.empty.view.purpose"), next: nil)
        }
    }

    private func show(_ scope: ListScope) {
        model.scope = scope
        model.persist()
    }
}
