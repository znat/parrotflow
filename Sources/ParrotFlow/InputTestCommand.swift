import Foundation

/// `--input-test "<field>" <caret> [selected] [limit]` — prints the three
/// blocks the `input` stage would publish, and reads nothing.
///
/// The one string step of the stage, which is also the only part of it that can
/// be scored: the capture itself is at the mercy of TCC and of whatever is
/// genuinely focused, and a fixture that stubbed a field would be scoring the
/// stub. What is testable is where the cut falls and what each side keeps when
/// the budget runs out.
///
/// `\n` in the argument is a newline, for the same reason `--context-test`
/// expands it.
enum InputTestCommand {

    static func run(field: String, caret: Int, selected: Int, limit: Int) -> Int32 {
        let text = ComposeCommand.expanded(field)
        let start = text.index(text.startIndex, offsetBy: min(caret, text.count))
        let end = text.index(start, offsetBy: min(selected, text.distance(from: start,
                                                                         to: text.endIndex)))
        let cut = InputBox.split(text, at: start..<end, limit: limit)
        print(cut.truncated ? "truncated" : "whole")
        print(cut.appending ? "appending" : "inserting")
        // Delimited, because the blocks keep their own spaces — the leading
        // one on `after` is a real character and a case file that trimmed it
        // would score a different string from the one the stage publishes.
        print("before ⟪\(cut.before)⟫")
        print("selection ⟪\(cut.selection)⟫")
        print("after ⟪\(cut.after)⟫")
        // The one line that survives a newline: the blocks above print theirs
        // raw, so a field with a break in it cannot be stated in this file at
        // all. This is what the log shows, escaped, and the escaping is the
        // point — `join` picks a different rule for a newline than for a space.
        let capture = InputBox.Capture(
            before: cut.before, selection: cut.selection, after: cut.after,
            text: nil, appending: cut.appending,
            total: text.count, truncated: cut.truncated)
        print("caret ⟪\(capture.neighbourhood ?? "")⟫", terminator: "")
        return 0
    }
}
