import AppKit
import ApplicationServices
import Foundation

/// `--field-dump [seconds]` — what the app can read out of the focused field.
///
///     ParrotFlow --field-dump 3
///     focus: Ghostty
///     value: 2443 chars, 48 line(s)
///        44 │ ❯ We use Superbase to host our databases.
///
/// `EditWatch` compares two of these to find a correction, and every failure it
/// had came from a wrong idea of what one contains: a status line, a keyboard
/// hint, this app's own log quoting the sentence. Printing it settles what is
/// actually there instead of guessing at it.
///
/// The delay is there because running this command puts the terminal in front:
/// give yourself time to click into whatever you meant to look at.
@available(macOS 14, *)
enum FieldDumpCommand {

    static func run(after seconds: Double) -> Int32 {
        if seconds > 0 {
            print("looking in \(Int(seconds))s — click into the field you mean")
            Thread.sleep(forTimeInterval: seconds)
        }
        guard let element = SelectionReader.focusedElement() else {
            print("✗ nothing is focused, or accessibility is not granted")
            return 1
        }
        let owner = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        print("focus: \(owner)")

        guard let value = CaretAnchor.snapshot(of: element) else {
            print("value: the field would not give it up")
            return 0
        }
        let lines = value.components(separatedBy: .newlines)
        print("value: \(value.count) chars, \(lines.count) line(s)")
        for (number, line) in lines.enumerated() where !line.isEmpty {
            print(String(format: "  %4d │ %@", number + 1, String(line.prefix(120))))
        }
        return 0
    }
}
