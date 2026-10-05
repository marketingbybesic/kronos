// Kronos/App/LiveUITest+ITmpl.swift — live proof that task templates can be found and used:
//  * the task row's context menu carries "Save as Template" (top-level rows only),
//  * running it stores a template with the task's title, notes and steps and raises the pill,
//  * the REAL File menu (NSApp.mainMenu) holds "New from Template" with that template and a
//    "Manage Templates…" row, and picking the template makes a NEW task with the same content,
//  * the palette has the save and manage commands, and the save command works too.
// Compiled only outside Release (LiveUITest itself is).
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    /// The item at `path` of the main menu bar, found by title (nil if any level is missing).
    private static func mainMenuItem(_ path: [String]) -> NSMenuItem? {
        var level: NSMenu? = NSApp.mainMenu
        var found: NSMenuItem?
        for title in path {
            guard let item = level?.items.first(where: { $0.title == title }) else { return nil }
            found = item
            level = item.submenu
        }
        return found
    }

    /// Every top-level menu's item titled `title` one level down (the File menu's own title is
    /// localized, so search all menus for the submenu by its item title).
    private static func fileMenuSubmenu(titled title: String) -> NSMenuItem? {
        for top in NSApp.mainMenu?.items ?? [] {
            // SwiftUI fills a menu when it is about to open; ask for that, as opening it would.
            if let menu = top.submenu {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
            }
            if let item = top.submenu?.items.first(where: { $0.title == title }) {
                if let inner = item.submenu {
                    inner.delegate?.menuNeedsUpdate?(inner)
                    inner.update()
                }
                return item
            }
        }
        return nil
    }

    static func iTmplSteps(_ model: AppModel) async {
        let store = model.store
        let tpls = TemplateStore.shared
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let name = "tplprobe sweep"
        let notes = "tplprobe notes body"

        let task = store.createNoUndo(title: name)
        store.update(task.id) { $0.notes = notes }
        guard store.addSubtaskNoUndo(task.id, title: "tplprobe step one") != nil,
              store.addSubtaskNoUndo(task.id, title: "tplprobe step two") != nil else {
            record("templates: fixture subtasks", false, "addSubtaskNoUndo returned nil"); return
        }
        let taskID = task.id
        let previousScope = model.scope
        model.scope = .all
        model.searchText = "tplprobe"
        model.selectedTaskID = nil
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(600))
        let templatesBefore = tpls.templates.count
        func probeTasks() -> [KTask] { store.allTasks().filter { $0.title == name && $0.parent == nil } }

        // 1. The row carries the menu with the item; a subtask row does not.
        let menuID = "row.\(taskID.uuidString)"
        let attached = await waitUntil { CtxMenuRegistry.providers[menuID] != nil }
        let nodes = CtxMenuRegistry.nodes(menuID) ?? []
        let item = CtxNodes.find(TaskMenu.saveTemplateNodeID, in: nodes)
        record("templates: the task row's context menu offers Save as Template",
               attached && item?.title == String(localized: "ctx.task.savetemplate") && item?.title == "Save as Template",
               "attached=\(attached) title=\(item?.title ?? "nil")")

        // 2. Running it stores the template (title, notes, both steps) and raises the pill with Manage.
        if !breakMode { _ = CtxNodes.invoke(TaskMenu.saveTemplateNodeID, in: nodes) }
        try? await Task.sleep(for: .milliseconds(300))
        let saved = tpls.templates.first { $0.name == name }
        record("templates: Save as Template stores title, notes and steps",
               saved?.title == name && saved?.notes == notes
                   && saved?.subtasks == ["tplprobe step one", "tplprobe step two"] && tpls.templates.count == templatesBefore + 1,
               "saved=\(saved?.name ?? "nil") steps=\(saved?.subtasks.count ?? -1) notes=\(saved?.notes ?? "nil") count \(templatesBefore)->\(tpls.templates.count)")
        let pill = UndoToastCenter.shared.current
        record("templates: saving raises the pill naming the template, with a Manage button",
               pill?.message.contains(name) == true && pill?.primaryTitle == String(localized: "undo.templatesaved.manage"),
               "message=\(pill?.message ?? "nil") primary=\(pill?.primaryTitle ?? "nil")")

        // 3. The real File menu lists the template and the manage row.
        // SwiftUI rebuilds the menu bar after the save; give it a moment.
        _ = await waitUntil(timeout: 4) {
            fileMenuSubmenu(titled: String(localized: "menu.file.newfromtemplate"))?.submenu?.items.contains { $0.title == name } == true
        }
        let sub = fileMenuSubmenu(titled: String(localized: "menu.file.newfromtemplate"))
        let kids = sub?.submenu?.items.map(\.title) ?? []
        record("templates: File menu has New from Template listing the template and Manage Templates…",
               kids.contains(name) && kids.contains(String(localized: "menu.file.templates.manage")),
               "items=\(kids)")

        // 4. Picking it in the File menu creates a NEW task with the same content.
        let before = probeTasks().count
        if let sub = sub?.submenu, let pick = sub.items.first(where: { $0.title == name }) {
            sub.performActionForItem(at: sub.index(of: pick))
        }
        try? await Task.sleep(for: .milliseconds(400))
        let after = probeTasks()
        let made = after.first { $0.id != taskID }
        record("templates: New from Template (File menu) makes a new task with the template's notes and steps",
               after.count == before + 1 && made?.notes == notes
                   && made?.orderedSubtasks.map(\.title) == ["tplprobe step one", "tplprobe step two"]
                   && model.selectedTaskID == made?.id,
               "tasks \(before)->\(after.count) notes=\(made?.notes ?? "nil") steps=\(made?.orderedSubtasks.count ?? -1) selected=\(model.selectedTaskID == made?.id)")

        // 5. Palette: both commands exist; Save runs through the same helper (second copy gets " 2").
        let commands = PaletteCommands.all(model: model)
        let hasManage = commands.contains { $0.id == "create.managetemplates" }
        let hasNew = commands.contains { $0.id == "create.fromtemplate" }
        model.selectedTaskID = taskID
        model.didMutate()
        let saveCmd = commands.first { $0.id == "task.savetemplate" }
        let available = saveCmd?.isAvailable(model) == true
        saveCmd?.run(model)
        try? await Task.sleep(for: .milliseconds(300))
        record("templates: palette has Save as Template, New from template and Manage templates",
               hasManage && hasNew && available && tpls.templates.contains { $0.name == name + " 2" },
               "manage=\(hasManage) new=\(hasNew) available=\(available) names=\(tpls.templates.map(\.name))")

        // Cleanup: tasks, templates, view state.
        for t in probeTasks() { store.softDelete(t.id) }
        for t in tpls.templates where t.name.hasPrefix(name) { tpls.delete(t.id) }
        model.scope = previousScope
        model.searchText = ""
        model.selectedTaskID = nil
        model.didMutate()
    }
}
#endif
