// Kronos/List/ListEmptyStates.swift
// What an empty list says: what the list is for (one line) and one next step, never a dead end
// ("Empty." alone told a new person nothing about Waiting or Someday). Today has its own clear
// state (TodayClear.swift); a search or filter that matches nothing says so in the list itself.
import SwiftUI
import KronosCore

struct ListEmptyState: View {
    @Bindable var model: AppModel

    var body: some View {
        let content = Self.content(for: model.scope)
        KEmptyState(icon: content.icon, title: content.title, message: content.purpose,
                    action: KEmptyState.Action(title: content.actionTitle) { run(content.action) })
            .uiTestAnchor("list.empty")
    }

    enum NextStep: Equatable {
        /// Focus the list's own "New task" row.
        case newTask
        /// Show another list.
        case show(ListScope)
    }

    struct Content {
        let icon: String
        let title: String
        let purpose: String
        let actionTitle: String
        let action: NextStep
    }

    static func content(for scope: ListScope) -> Content {
        let newTask = String(localized: "list.new")
        switch scope {
        case .inbox:
            return Content(icon: "inbox", title: String(localized: "empty.inbox.body"),
                           purpose: String(localized: "list.empty.inbox.purpose"), actionTitle: newTask, action: .newTask)
        case .today:
            return Content(icon: "sun", title: String(localized: "today.clear.title"),
                           purpose: String(localized: "today.clear.hint"), actionTitle: newTask, action: .newTask)
        case .next7:
            return Content(icon: "calendar-days", title: String(localized: "empty.next7.body"),
                           purpose: String(localized: "list.empty.next7.purpose"),
                           actionTitle: String(localized: "list.empty.action.inbox"), action: .show(.inbox))
        case .waiting:
            return Content(icon: "hourglass", title: String(localized: "list.empty.waiting.title"),
                           purpose: String(localized: "list.empty.waiting.purpose"),
                           actionTitle: String(localized: "list.empty.action.all"), action: .show(.all))
        case .someday:
            return Content(icon: "archive", title: String(localized: "list.empty.someday.title"),
                           purpose: String(localized: "list.empty.someday.purpose"),
                           actionTitle: String(localized: "list.empty.action.inbox"), action: .show(.inbox))
        case .project, .area:
            return Content(icon: "folder", title: String(localized: "list.empty.project.title"),
                           purpose: String(localized: "list.empty.project.purpose"), actionTitle: newTask, action: .newTask)
        case .all, .savedView:
            return Content(icon: "list-ordered", title: String(localized: "empty.view.body"),
                           purpose: String(localized: "list.empty.view.purpose"), actionTitle: newTask, action: .newTask)
        }
    }

    private func run(_ step: NextStep) {
        switch step {
        case .newTask:
            NotificationCenter.default.post(name: Notification.Name("kronosNewTaskRequested"), object: nil)
        case .show(let scope):
            model.scope = scope
            model.persist()
        }
    }
}
