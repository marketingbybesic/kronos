// Kronos/Welcome/WelcomeGate.swift
// Pure decision for what to show at launch: the welcome tour, the permissions window, both,
// or neither. Foundation-only so the welcome flow self-test script can compile and test
// it standalone, the same way PermissionRowLogic is tested. AppDelegate calls `decide` once
// and acts on the result; it holds no branching of its own.
import Foundation

enum WelcomeGate {
    /// `env` is the three hermetic guards (`KRONOS_SNAPSHOT`, `KRONOS_STORE_DIR`,
    /// `KRONOS_SELFTEST`) — any one present means neither window may ever open.
    /// `welcomeShown` / `permissionsShown` are the two independent UserDefaults flags
    /// (`kronos.welcome.shownOnce`, `kronos.permissions.shownOnce`). Permissions only ever
    /// follows Welcome in the same launch (never shown twice, never shown alone once Welcome
    /// exists): an existing user who already saw Permissions still sees Welcome once, but
    /// Welcome closing for a user who already saw Permissions does not reopen it.
    static func decide(env: [String: String], welcomeShown: Bool, permissionsShown: Bool)
        -> (showWelcome: Bool, showPermissionsAfter: Bool) {
        guard env["KRONOS_SNAPSHOT"] == nil, env["KRONOS_STORE_DIR"] == nil, env["KRONOS_SELFTEST"] == nil else {
            return (false, false)
        }
        guard !welcomeShown else { return (false, false) }
        return (true, !permissionsShown)
    }
}
