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
        // Clamped at both ends. A caret past the end is a real case — the value
        // and the selection are read in two calls and an edit can land between
        // them — and a negative one traps rather than misbehaving. `main.swift`
        // refuses negatives before getting here; this makes the function total.
        let from = min(max(0, caret), text.count)
        let start = text.index(text.startIndex, offsetBy: from)
        let span = min(max(0, selected), text.distance(from: start, to: text.endIndex))
        let end = text.index(start, offsetBy: span)
        let cut = InputBox.split(text, at: start..<end, limit: max(0, limit))
        print(cut.truncated ? "truncated" : "whole")
        print(cut.appending ? "appending" : "inserting")
        // Delimited, because the blocks keep their own spaces — the leading
        // one on `after` is a real character and a case file that trimmed it
        // would score a different string from the one the stage publishes.
        print("before ⟪\(cut.before)⟫")
        print("selection ⟪\(cut.selection)⟫")
        print("after ⟪\(cut.after)⟫", terminator: "")
        return 0
    }
}
