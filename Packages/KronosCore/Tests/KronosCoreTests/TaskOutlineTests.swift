import Testing
@testable import KronosCore

/// Expectations written by hand, one shape of input per case.
struct TaskOutlineTests {
    typealias Item = TaskOutline.Item

    @Test func oneLineWithArrowsMakesSubtasks() {
        #expect(TaskOutline.parse("Prepare the offer > find the template > fill in prices")
                == [Item(line: "Prepare the offer", subtasks: ["find the template", "fill in prices"])])
    }

    @Test func plainLineIsOneTask() {
        #expect(TaskOutline.parse("Call Alex !! tomorrow") == [Item(line: "Call Alex !! tomorrow")])
    }

    @Test func arrowWithoutSpacesOrWithAnEmptySideStaysText() {
        #expect(TaskOutline.parse("Check x>y in the report") == [Item(line: "Check x>y in the report")])
        #expect(TaskOutline.parse("Is margin > ") == [Item(line: "Is margin >")])
    }

    @Test func tabIndentedLinesAreSubtasks() {
        let text = "Ship the newsletter\n\tWrite the intro\n\tPick three links\nBook the dentist"
        #expect(TaskOutline.parse(text) == [Item(line: "Ship the newsletter", subtasks: ["Write the intro", "Pick three links"]),
                                            Item(line: "Book the dentist")])
    }

    @Test func bulletsUnderAPlainLineAreSubtasks() {
        let text = "Onboard Globex\n- send the contract\n- schedule the kickoff"
        #expect(TaskOutline.parse(text) == [Item(line: "Onboard Globex", subtasks: ["send the contract", "schedule the kickoff"])])
    }

    @Test func aFlatBulletedListIsAListOfTasks() {
        let text = "- Pay the invoice\n- Renew the domain\n* Call the accountant"
        #expect(TaskOutline.parse(text) == [Item(line: "Pay the invoice"), Item(line: "Renew the domain"), Item(line: "Call the accountant")])
    }

    @Test func nestedBulletsBelongToTheBulletAboveThem() {
        let text = "- Launch page\n  - write copy\n  - [ ] export images\n- Send recap"
        #expect(TaskOutline.parse(text) == [Item(line: "Launch page", subtasks: ["write copy", "export images"]), Item(line: "Send recap")])
    }

    @Test func blankLinesAndAnIndentedFirstLineAreHarmless() {
        #expect(TaskOutline.parse("\n\n   Orphan line\n\n") == [Item(line: "Orphan line")])
        #expect(TaskOutline.parse("") == [])
    }

    @Test func arrowsWorkInsideAnIndentedLineToo() {
        #expect(TaskOutline.parse("Plan trip\n\tbook flight > book hotel")
                == [Item(line: "Plan trip", subtasks: ["book flight", "book hotel"])])
    }

    // "-" or ">" or a Tab in ANY mix must all create subtasks of the task above. `>` at the
    // START of a line is a bullet marker (TaskOutline.swift:52's marker list also has
    // `-`/`*`/bullets), distinct from `>` used mid-line as the arrow separator (`split`,
    // covered above).
    @Test func rightAngleBracketIsALineStartBullet() {
        let text = "Prepare the offer\n> find the template\n> fill in prices"
        #expect(TaskOutline.parse(text)
                == [Item(line: "Prepare the offer", subtasks: ["find the template", "fill in prices"])])
    }

    @Test func mixedDashAngleAndTabSubtasksInOneGroup() {
        let text = "Task\n- sub\n> sub\n\tsub"
        #expect(TaskOutline.parse(text) == [Item(line: "Task", subtasks: ["sub", "sub", "sub"])])
    }
}
