import Foundation

// Strings read off a scratch Chrome 154 contenteditable shaped like Slack's
// composer, everything selected: AXValue, then AXSelectedText.
@main
enum AppOffsetsTests {
    static func placed(_ before: String, _ selected: String, in value: String) -> String? {
        AppOffsets.valueRange(before: before, selected: selected, in: value).map { String(value[$0]) }
    }

    static func main() {
        let threeValue = "Hey \u{FEFF}@channel\u{FEFF}. We're just three weeks away from the team retreat, and it's "
            + "time to start booking travel and rooms.\nPlease add your arrival and departure dates to "
            + "the shared sheet by Friday, and flag any dietary needs or access requirements.\nWe'll send "
            + "the final agenda next week. Questions about the venue? Drop them in "
            + "\u{FEFF}#retreat-planning\u{FEFF}.\n"
        let threeSelected = "Hey \u{FEFF}@channel\u{FEFF}. We're just three weeks away from the team retreat, and it's "
            + "time to start booking travel and rooms.Please add your arrival and departure dates to the "
            + "shared sheet by Friday, and flag any dietary needs or access requirements.We'll send the "
            + "final agenda next week. Questions about the venue? Drop them in "
            + "\u{FEFF}#retreat-planning\u{FEFF}.\n"
        precondition(threeValue.utf16.count == 342 && threeSelected.utf16.count == 340, "the captured lengths")
        precondition(placed("", threeSelected, in: threeValue) == threeValue,
                     "all of three paragraphs covers the whole value")

        let mixedValue = "Hey \u{FEFF}@channel\u{FEFF}. Three weeks to the retreat.\nBook travel this week.\nArrival "
            + "dates go in the sheet.\nDietary needs too.\nQuestions? Ask in "
            + "\u{FEFF}#retreat-planning\u{FEFF}.\n\n"
        let mixedSelected = "Hey \u{FEFF}@channel\u{FEFF}. Three weeks to the retreat.Book travel this week.\nArrival "
            + "dates go in the sheet.\nDietary needs too.Questions? Ask in "
            + "\u{FEFF}#retreat-planning\u{FEFF}.\n\n"
        precondition(placed("", mixedSelected, in: mixedValue) == mixedValue,
                     "a blank line, a soft break and two trailing empty lines")

        precondition(placed(
            "Hey \u{FEFF}@channel\u{FEFF}. Three weeks to the retreat.",
            "Book travel this week.\nArrival dates go in the sheet.\nDietary needs too.Questions? Ask",
            in: mixedValue
        ) == "Book travel this week.\nArrival dates go in the sheet.\nDietary needs too.\nQuestions? Ask",
                     "a selection that starts after a paragraph break")

        let range = AppOffsets.valueRange(
            before: "Hey \u{FEFF}@channel\u{FEFF}. Three weeks to the retreat.", selected: "Book", in: mixedValue)
        precondition(range.map { NSRange($0, in: mixedValue).location } == 44,
                     "the start moves past the break the app does not count")

        let native = "Hey @channel. Three weeks.\nBook travel.\n"
        precondition(placed("Hey @channel. ", "Three weeks.\nBook", in: native) == "Three weeks.\nBook",
                     "a field whose offsets already address its value")

        precondition(placed("", "Hey \u{FEFF}@channel\u{FEFF}. Four weeks", in: mixedValue) == nil,
                     "text that is no longer there")
        precondition(placed("Hi ", "\u{FEFF}@channel", in: mixedValue) == nil,
                     "a prefix that is no longer there")
        precondition(placed("", "", in: mixedValue) == nil, "nothing selected")
        precondition(placed("Jerry and ", "Jerry", in: "Jerry and Jerry") == "Jerry",
                     "the copy at the offset, not the first one")
        precondition(AppOffsets.valueRange(before: "Jerry and ", selected: "Jerry", in: "Jerry and Jerry")
            .map { NSRange($0, in: "Jerry and Jerry").location } == 10, "the second copy")

        func app(_ location: Int, _ length: Int, _ app: String, in value: String) -> NSRange? {
            AppOffsets.appRange(of: NSRange(location: location, length: length), app: app, in: value)
        }
        precondition(app(0, 342, threeSelected, in: threeValue) == NSRange(location: 0, length: 340),
                     "the whole value is the whole app text")
        precondition(app(116, 31, threeSelected, in: threeValue) == NSRange(location: 115, length: 31),
                     "a span below one paragraph break moves back by one")
        precondition(app(116, 31, String(threeSelected.prefix(146)), in: threeValue)
            == NSRange(location: 115, length: 31), "app text read only as far as the span")
        precondition(app(242, 4, threeSelected, in: threeValue) == NSRange(location: 240, length: 4),
                     "a span below two paragraph breaks moves back by two")
        precondition(app(43, 5, mixedSelected, in: mixedValue) == NSRange(location: 43, length: 4),
                     "a span that starts on the break the app does not count")
        precondition(app(44, 0, mixedSelected, in: mixedValue) == NSRange(location: 43, length: 0),
                     "an insertion point after a break")
        precondition(app(14, 17, native, in: native) == NSRange(location: 14, length: 17),
                     "a field whose offsets already address its value")
        precondition(app(0, 4, "Hi \u{FEFF}@channel", in: mixedValue) == nil,
                     "app text that is not the value's")

        precondition(AppOffsets.shown(threeSelected, at: 0, in: threeValue) { "" } == threeValue,
                     "three paragraphs, all selected, read with their breaks")
        let mentionLine = "Hey \u{FEFF}@channel\u{FEFF}. Three weeks to the retreat."
        precondition(AppOffsets.shown(
            "Book travel this week.\nArrival dates go in the sheet.\nDietary needs too.Questions? Ask",
            at: mentionLine.utf16.count, in: mixedValue
        ) { mentionLine } == "Book travel this week.\nArrival dates go in the sheet.\nDietary needs too.\nQuestions? Ask",
                     "a selection that starts after a paragraph break, read with its breaks")
        var asked = false
        precondition(AppOffsets.shown("Three weeks.\nBook", at: 14, in: native) { asked = true; return nil }
            == "Three weeks.\nBook" && !asked, "a field whose offsets already address its value")
        precondition(AppOffsets.shown("Dietary needs too.Questions? Ask", at: 110, in: mixedValue) { nil }
            == "Dietary needs too.Questions? Ask", "the app will not say what comes before")
        precondition(AppOffsets.shown("Four weeks", at: 0, in: mixedValue) { "" } == "Four weeks",
                     "text that is no longer there")

        print("app offsets: every case passed")
    }
}
