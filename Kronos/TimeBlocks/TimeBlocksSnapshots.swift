// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols.
#if !RELEASE
// Kronos/TimeBlocks/TimeBlocksSnapshots.swift
// Named screens for Kronos/Shared/SnapshotHarness.swift. `TimeBlocksSnapshots.screens(model:)`
// is wired into that file's registry array. Seeding happens in the returned view's
// `.onAppear`, never while this dictionary is built.
import SwiftUI
import KronosCore

@MainActor
enum TimeBlocksSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            // G3: a block in progress with two linked tasks (one direct task link, one via the
            // block's matched project) plus a third, unrelated task that must NOT appear.
            "timeblocks.current": AnyView(CurrentBlockHost(model: model)),
            // G3: the block resolved to a project but nothing in the store links to it.
            "timeblocks.empty": AnyView(EmptyBlockHost(model: model)),
            // G3: `now` is frozen past the current block's end — the switch/stay prompt shows.
            "timeblocks.ended": AnyView(EndedBlockHost(model: model)),
        ]
    }
}

/// Fixed reference instant every fixture builds around, so "in progress" / "ended" are facts
/// about the fixture's own numbers, never a race against the real clock.
private let fixtureNow = Date(timeIntervalSince1970: 1_726_800_000)   // 2024-09-20 04:00:00 UTC

private func fixtureEvent(id: String, title: String, startOffset: TimeInterval, endOffset: TimeInterval) -> KCalendarEvent {
    KCalendarEvent(id: id, title: title, start: fixtureNow.addingTimeInterval(startOffset),
                  end: fixtureNow.addingTimeInterval(endOffset), isAllDay: false, calendarID: "fixture")
}

private struct CurrentBlockHost: View {
    let model: AppModel
    @State private var blocks: [TimeBlockEntry] = []
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TimeBlocksScreen(model: model, previewBlocks: blocks, previewNow: fixtureNow)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            let project = model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[10].hex, icon: "briefcase", area: nil)
            let directLinkEvent = fixtureEvent(id: "evt-current", title: "Acme blok", startOffset: -600, endOffset: 1800)
            // Realistic block load: several tasks matched by project, one by a direct task link
            // — both matching mechanisms exercised on one screen, at a task count a busy block
            // actually carries (a two-row screen under-represents the real feature).
            for title in ["Pripremi Acme prezentaciju", "Provjeri Acme ugovor", "Javi se Acme timu",
                          "Ažuriraj Acme troškovnik", "Pregledaj Acme povratne informacije", "Zakaži Acme sastanak",
                          "Pripremi Acme agendu", "Provjeri Acme fakture"] {
                _ = model.store.create(title: title, notes: "", project: project, status: .todo, priority: .high, dueDay: nil)
            }
            let linkedByTask = model.store.create(title: "Pošalji Acme ponudu", notes: "", project: nil,
                                                  status: .todo, priority: .medium, dueDay: nil)
            let link = TaskCalendarLink(eventID: directLinkEvent.id, title: directLinkEvent.title,
                                        start: directLinkEvent.start, end: directLinkEvent.end)
            model.store.update(linkedByTask.id) { $0.notes = link.appending(to: $0.notes) }
            // Unrelated task — must NOT appear on this screen (proves the filter, not just "some rows").
            _ = model.store.create(title: "Nepovezan zadatak", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
            // A second block later today — real days have more than one, and the day strip
            // (shown once there are 2+ blocks) needs a second chip to prove it renders at all.
            let laterEvent = fixtureEvent(id: "evt-later", title: "Globex poziv", startOffset: 3600, endOffset: 5400)
            blocks = [TimeBlockEntry(event: directLinkEvent, projectID: project.id),
                     TimeBlockEntry(event: laterEvent, projectID: nil)]
            model.didMutate()
            didSeed = true
        }
    }
}

private struct EmptyBlockHost: View {
    let model: AppModel
    @State private var blocks: [TimeBlockEntry] = []
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TimeBlocksScreen(model: model, previewBlocks: blocks, previewNow: fixtureNow)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            let project = model.store.createProject(name: "Globex", colorHex: KProjectPalette.swatches[6].hex, icon: "briefcase", area: nil)
            let event = fixtureEvent(id: "evt-empty", title: "Globex blok", startOffset: -300, endOffset: 900)
            // A second block later today so the day strip (2+ blocks) renders here too — an
            // empty current block is not necessarily the only block of the day.
            let laterEvent = fixtureEvent(id: "evt-empty-later", title: "Acme poziv", startOffset: 3600, endOffset: 5400)
            blocks = [TimeBlockEntry(event: event, projectID: project.id), TimeBlockEntry(event: laterEvent, projectID: nil)]
            model.didMutate()
            didSeed = true
        }
    }
}

private struct EndedBlockHost: View {
    let model: AppModel
    @State private var blocks: [TimeBlockEntry] = []
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TimeBlocksScreen(model: model, previewBlocks: blocks, previewNow: fixtureNow)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            let project = model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[10].hex, icon: "briefcase", area: nil)
            for title in ["Pripremi Acme prezentaciju", "Provjeri Acme ugovor", "Javi se Acme timu",
                          "Zakaži Acme sastanak", "Ažuriraj Acme troškovnik", "Pripremi Acme agendu"] {
                _ = model.store.create(title: title, notes: "", project: project, status: .todo, priority: .high, dueDay: nil)
            }
            // Ended well before fixtureNow, with a next block still ahead so the prompt's
            // "switch to <next>" wording has something real to name.
            let ended = fixtureEvent(id: "evt-ended", title: "Acme blok", startOffset: -3600, endOffset: -600)
            let next = fixtureEvent(id: "evt-next", title: "Globex poziv", startOffset: 600, endOffset: 2400)
            blocks = [TimeBlockEntry(event: ended, projectID: project.id), TimeBlockEntry(event: next, projectID: nil)]
            model.didMutate()
            didSeed = true
        }
    }
}
#endif
