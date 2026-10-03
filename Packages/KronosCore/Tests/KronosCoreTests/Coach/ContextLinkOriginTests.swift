import Testing
import Foundation
@testable import KronosCore

/// Device-local links carry the device that made them as a fourth `|` field. Expectations are
/// literal lines, never produced by the code under test.
struct ContextLinkOriginTests {
    private let mac = DeviceOrigin(id: "a1b2c3d4", name: "MacBook Pro")
    private let phone = DeviceOrigin(id: "99887766", name: "iPhone")

    @Test func originIsAFourthFieldAndThreeFieldLinesAreUnchanged() {
        let old = ContextLink(kind: .file, reference: "bm==", displayName: "Plan.pdf")
        #expect(old.encodedLine == "link://file|Plan.pdf|bm==")
        let stamped = old.stamped(with: mac)
        #expect(stamped.encodedLine == "link://file|Plan.pdf|bm==|a1b2c3d4~MacBook Pro")
        // Round trip through find.
        #expect(ContextLink.findAll(in: stamped.encodedLine) == [stamped])
        #expect(ContextLink.findAll(in: "link://file|Plan.pdf|bm==") == [old])
    }

    @Test func webLinksAreNeverStamped() {
        let web = ContextLink(kind: .web, reference: "https://example.com", displayName: "Example")
        #expect(web.stamped(with: mac) == web)
        #expect(web.stamped(with: mac).encodedLine == "link://web|Example|https://example.com")
        #expect(!web.isDeviceLocal)
    }

    // Hand-written table: kind -> device-local.
    @Test func whichKindsAreDeviceLocal() {
        let table: [(ContextLink.Kind, Bool)] = [(.file, true), (.folder, true), (.email, true), (.appleNote, true), (.web, false)]
        for (kind, local) in table {
            #expect(ContextLink(kind: kind, reference: "r", displayName: "n").isDeviceLocal == local, "\(kind)")
        }
    }

    @Test func existingOriginIsKept() {
        let made = ContextLink(kind: .folder, reference: "bm==", displayName: "Projects").stamped(with: mac)
        #expect(made.stamped(with: phone).origin == mac.token)
    }

    // Foreign-device table: (origin on link, this device) -> shown name.
    @Test func foreignDeviceName() {
        let onMac = ContextLink(kind: .file, reference: "bm==", displayName: "Plan.pdf").stamped(with: mac)
        #expect(onMac.foreignDeviceName(on: phone) == "MacBook Pro")
        #expect(onMac.foreignDeviceName(on: mac) == nil)
        // Renamed Mac: same id, other name, still this device.
        #expect(onMac.foreignDeviceName(on: DeviceOrigin(id: "a1b2c3d4", name: "Studio")) == nil)
        // No origin recorded (written before origins existed): treated as usable.
        #expect(ContextLink(kind: .file, reference: "bm==", displayName: "Plan.pdf").foreignDeviceName(on: phone) == nil)
        // Unknown current device: never claims a link is foreign.
        #expect(onMac.foreignDeviceName(on: nil) == nil)
        // Web links are not foreign anywhere, even with a hand-made origin.
        #expect(ContextLink(kind: .web, reference: "https://x.com", displayName: "x", origin: mac.token).foreignDeviceName(on: phone) == nil)
        // Unreadable origin token.
        #expect(ContextLink(kind: .file, reference: "bm==", displayName: "n", origin: "garbage").foreignDeviceName(on: phone) == nil)
    }

    // Explicit device only: the global `DeviceOrigin.current` is never touched here, because
    // other suites append links in parallel.
    @Test func appendingStampsWithTheGivenDevice() {
        let link = ContextLink(kind: .email, reference: "message:%3Cq%3E", displayName: "Question")
        #expect(link.appending(to: "", device: nil) == "link://email|Question|message:%253Cq%253E")
        let text = link.appending(to: "note", device: mac)
        #expect(text == "note\nlink://email|Question|message:%253Cq%253E|a1b2c3d4~MacBook Pro")
        // Attaching the same item again changes nothing, stamped or not.
        #expect(link.appending(to: text, device: phone) == text)
        #expect(link.appending(to: text, device: nil) == text)
        // Web links stay three-field even with a device.
        let web = ContextLink(kind: .web, reference: "https://example.com", displayName: "Example")
        #expect(web.appending(to: "", device: mac) == "link://web|Example|https://example.com")
    }

    @Test func removingStillMatchesOnKindAndReferenceOnly() {
        let stamped = ContextLink(kind: .file, reference: "bm==", displayName: "Plan.pdf").stamped(with: mac)
        let text = "keep\n" + stamped.encodedLine
        #expect(ContextLink.removing(ContextLink(kind: .file, reference: "bm==", displayName: "Plan.pdf"), from: text) == "keep")
    }

    @Test func originWithSeparatorsSurvivesEscaping() {
        let odd = DeviceOrigin(id: "ab12cd34", name: "Alex's | Mac ~ Pro")
        let link = ContextLink(kind: .file, reference: "bm==", displayName: "n").stamped(with: odd)
        let back = ContextLink.findAll(in: link.encodedLine)
        #expect(back.count == 1)
        #expect(back.first?.foreignDeviceName(on: mac) == "Alex's | Mac ~ Pro")
    }

    @Test func deviceTokenParsing() {
        #expect(DeviceOrigin(token: "a1b2~Mac")?.name == "Mac")
        #expect(DeviceOrigin(token: "a1b2~Mac ~ Pro")?.name == "Mac ~ Pro")
        #expect(DeviceOrigin(token: "a1b2~")?.name == "a1b2")
        #expect(DeviceOrigin(token: "~Mac") == nil)
        #expect(DeviceOrigin(token: "nodash") == nil)
    }

    @Test func liveDeviceIdIsCreatedOnceAndKept() {
        let suite = "kronos.test.device.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DeviceOrigin.live(defaults: defaults, name: "A")
        let second = DeviceOrigin.live(defaults: defaults, name: "B")
        #expect(first.id.count == 8)
        #expect(first.id == second.id)
        #expect(second.name == "B")
    }
}
