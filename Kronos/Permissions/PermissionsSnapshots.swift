// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols.
#if !RELEASE
// Kronos/Permissions/PermissionsSnapshots.swift
// Extra named screens for Kronos/Shared/SnapshotHarness.swift.
// Every status is a fixture (`FixturePermissionsStatus`) — never real system state, and
// `allow(_:)`'s Calendar path never actually fires under KRONOS_SNAPSHOT (CoachModel's own
// guard), so no shot can ever raise a system prompt.
import SwiftUI
import KronosCore

@MainActor
enum PermissionsSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "permissions": AnyView(preview(statuses: [:])),
            "permissions.mixed": AnyView(preview(statuses: [
                .calendar: .granted, .notes: .denied,
            ])),
            "permissions.granted": AnyView(preview(statuses: [
                .calendar: .granted, .notes: .granted, .launchAtLogin: .granted, .claudeAccess: .granted,
            ])),
        ]
    }

    private static func preview(statuses: [PermissionKind: PermissionStatus]) -> some View {
        let fixture = FixturePermissionsStatus(statuses: statuses)
        let permModel = PermissionsModel(statusProvider: fixture, requestCalendarAccess: {})
        return PermissionsWindow(model: permModel)
            .fixedSize()
    }
}
#endif
