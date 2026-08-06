import Foundation

/// `--context-test "<screen>" [limit]` — prints what the `context` stage would
/// publish for a screen handed to it, and reads nothing.
///
/// The two string steps of the stage, in the order they run: cut the input box
/// off the bottom, then keep the tail. Neither touches accessibility, so both
/// can be scored exactly — which is the only part of this stage that can be.
/// The capture itself is at the mercy of TCC and of whatever is genuinely in
/// front, and a fixture that stubbed a screen would be scoring the stub.
///
/// `\n` in the argument is a newline, because a case file is line-oriented and
/// the thing being scored is where the rows are.
enum ContextTestCommand {

    static func run(screen: String, limit: Int) -> Int32 {
        let above = Context.aboveInputBox(in: ComposeCommand.expanded(screen))
        let (text, truncated) = Context.tail(of: above, limit: limit)
        print(truncated ? "truncated" : "whole")
        print(text, terminator: "")
        return 0
    }
}
