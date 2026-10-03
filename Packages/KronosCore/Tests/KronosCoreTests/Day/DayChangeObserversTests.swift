// DayChangeObservers is the platform half of day-change handling (AppKit on the Mac, UIKit on
// iPhone/iPad/Vision, WatchKit on the Watch). These tests run on whichever platform the package
// is built for and use private notification centers, so nothing here touches the system's.

import Testing
import Foundation
@testable import KronosCore

@MainActor
private final class NoopScheduler: DayChangeScheduling {
    func schedule(at date: Date, _ fire: @escaping () -> Void) {}
    func cancel() {}
}

@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Suite(.serialized) @MainActor
struct DayChangeObserversTests {
    private func makeRig() -> (DayChangeCoordinator, FixtureClock, DayChangeObservers, NotificationCenter, NotificationCenter) {
        let clock = FixtureClock(day: Day.parseISO("2026-10-03") ?? 0)
        let coordinator = DayChangeCoordinator(clock: clock, scheduler: NoopScheduler(), defaults: FixtureKeyValueStore())
        coordinator.start()
        let workspace = NotificationCenter(), system = NotificationCenter()
        let observers = DayChangeObservers(coordinator: coordinator, workspaceCenter: workspace, systemCenter: system)
        return (coordinator, clock, observers, workspace, system)
    }

    private func countDayChanges(of coordinator: DayChangeCoordinator, _ body: () async -> Void) async -> Int {
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: .kronosDayDidChange, object: coordinator, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        await body()
        await settle { count >= 1 }
        // Let any extra (wrong) deliveries land before reading.
        try? await Task.sleep(nanoseconds: 30_000_000)
        return count
    }

    @Test func calendarDayChangedSignalChecksTheDay() async {
        let (coord, clock, observers, _, system) = makeRig()
        let fired = await countDayChanges(of: coord) {
            clock.advance(hours: 16)
            system.post(name: .NSCalendarDayChanged, object: nil)
        }
        #expect(fired == 1)
        withExtendedLifetime(observers) {}
    }

    @Test func timeZoneChangeSignalChecksTheDay() async {
        let (coord, clock, observers, _, system) = makeRig()
        let fired = await countDayChanges(of: coord) {
            clock.advance(hours: 16)
            system.post(name: .NSSystemTimeZoneDidChange, object: nil)
        }
        #expect(fired == 1)
        withExtendedLifetime(observers) {}
    }

    // Positive control: the day moved but no signal arrived, so nothing may fire; the two tests
    // above fail if the observers are not wired.
    @Test func noSignalNoCheck() async {
        let (coord, clock, observers, _, _) = makeRig()
        let fired = await countDayChanges(of: coord) {
            clock.advance(hours: 16)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fired == 0)
        withExtendedLifetime(observers) {}
    }

    @Test func releasedObserversStopListening() async {
        var rig: (DayChangeCoordinator, FixtureClock, DayChangeObservers?, NotificationCenter, NotificationCenter)? = {
            let r = makeRig()
            return (r.0, r.1, r.2, r.3, r.4)
        }()
        let coord = rig!.0, clock = rig!.1, system = rig!.4
        rig!.2 = nil
        let fired = await countDayChanges(of: coord) {
            clock.advance(hours: 16)
            system.post(name: .NSCalendarDayChanged, object: nil)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fired == 0)
        rig = nil
    }
}
