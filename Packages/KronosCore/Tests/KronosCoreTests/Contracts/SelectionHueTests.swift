import Testing
import Foundation
@testable import KronosCore

/// Hand-written expectation table: (own project hex, parent's project hex, neutral mode) -> hue.
/// Nothing here is computed by the code under test.
struct SelectionHueTests {

    private struct Row {
        let name: String
        let own: String?
        let parent: String?
        let neutral: Bool
        let expected: SelectionHue
    }

    private static let table: [Row] = [
        Row(name: "own project",                  own: "#F2994A", parent: nil,       neutral: false, expected: .project(hex: "#F2994A")),
        Row(name: "own project beats parent's",   own: "#F2994A", parent: "#2F80ED", neutral: false, expected: .project(hex: "#F2994A")),
        Row(name: "child inherits parent's",      own: nil,       parent: "#2F80ED", neutral: false, expected: .project(hex: "#2F80ED")),
        Row(name: "no project anywhere = accent", own: nil,       parent: nil,       neutral: false, expected: .accent),
        Row(name: "lower-case, no hash",          own: "f2994a",  parent: nil,       neutral: false, expected: .project(hex: "#F2994A")),
        Row(name: "padded",                       own: " #2f80ed ", parent: nil,     neutral: false, expected: .project(hex: "#2F80ED")),
        Row(name: "empty own falls to parent",    own: "",        parent: "#2F80ED", neutral: false, expected: .project(hex: "#2F80ED")),
        Row(name: "malformed own falls to parent", own: "orange", parent: "#2F80ED", neutral: false, expected: .project(hex: "#2F80ED")),
        Row(name: "short hex is malformed",       own: "#F29",    parent: nil,       neutral: false, expected: .accent),
        Row(name: "non-hex digits are malformed", own: "#GGGGGG", parent: "#12",     neutral: false, expected: .accent),
        Row(name: "neutral beats own project",    own: "#F2994A", parent: nil,       neutral: true,  expected: .white),
        Row(name: "neutral beats parent project", own: nil,       parent: "#2F80ED", neutral: true,  expected: .white),
        Row(name: "neutral with nothing",         own: nil,       parent: nil,       neutral: true,  expected: .white),
    ]

    @Test(arguments: table.indices)
    func tableRowResolves(_ i: Int) {
        let r = Self.table[i]
        #expect(SelectionHue.resolve(projectHex: r.own, parentProjectHex: r.parent, neutral: r.neutral) == r.expected, "\(r.name)")
    }

    // MARK: - From real tasks

    @Test func taskWithProjectUsesProjectColour() {
        let p = KProject(name: "Alpha", colorHex: "#F2994A", icon: "circle", area: nil, sortIndex: 0)
        let t = KTask(title: "t", project: p)
        #expect(SelectionHue.forTask(t, neutral: false) == .project(hex: "#F2994A"))
    }

    @Test func taskWithoutProjectUsesAccent() {
        #expect(SelectionHue.forTask(KTask(title: "t"), neutral: false) == .accent)
    }

    @Test func childInheritsParentsProject() {
        let p = KProject(name: "Beta", colorHex: "#2F80ED", icon: "circle", area: nil, sortIndex: 0)
        let parent = KTask(title: "parent", project: p)
        let child = KTask(title: "child")
        child.parent = parent
        #expect(SelectionHue.forTask(child, neutral: false) == .project(hex: "#2F80ED"))
        #expect(SelectionHue.forTask(child, neutral: true) == .white)
    }

    @Test func childOfProjectlessParentUsesAccent() {
        let parent = KTask(title: "parent")
        let child = KTask(title: "child")
        child.parent = parent
        #expect(SelectionHue.forTask(child, neutral: false) == .accent)
    }

    // MARK: - Positive control: the comparison can fail

    @Test func controlTableCanFail() {
        // A deliberately wrong expectation must not match, proving `==` is not vacuous.
        #expect(SelectionHue.resolve(projectHex: "#F2994A", neutral: false) != .accent)
        #expect(SelectionHue.resolve(projectHex: "#F2994A", neutral: false) != .project(hex: "#2F80ED"))
        #expect(SelectionHue.resolve(projectHex: nil, neutral: false) != .white)
    }
}
