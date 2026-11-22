import Foundation

enum SelectionReader {}

/// The shapes are Claude Code's, read from live Ghostty panes on 2026-11-22.
@main
enum InputRowTests {
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var passed = 0

    static let rule = String(repeating: "─", count: 95)
    static let labelled = String(repeating: "─", count: 58) + " a session with a name ─"
    static let status = "  ⏵⏵ accept edits on (shift+tab to cycle)"

    /// What is on the line the pill would open under.
    static func line(_ rows: [String]) -> String? {
        let screen = rows.joined(separator: "\n")
        guard let offset = SelectionReader.lastInputOffset(in: screen, rows: 70) else { return nil }
        let text = screen as NSString
        return text.substring(with: text.lineRange(for: NSRange(location: offset, length: 0)))
            .trimmingCharacters(in: .newlines)
    }

    static func check(_ what: String, _ rows: [String], _ want: String?) {
        let got = line(rows)
        if got == want { passed += 1; return }
        failed += 1
        print("  ✗ \(what): got \(got ?? "nothing"), want \(want ?? "nothing")")
    }

    static func main() {
        check("a plain box", ["output", rule, "❯ hello", rule, status], "❯ hello")
        check("a box with a label in its top rule", ["output", labelled, "❯ hello", rule, status], "❯ hello")
        check("a labelled box, two rows typed",
              ["output", labelled, "❯ hello", "  and more", rule, status], "  and more")
        check("an empty labelled box", ["output", labelled, "❯ ", rule, status], "❯ ")
        check("a labelled box under an older plain one",
              [rule, "❯ old", rule, "output", labelled, "❯ hello", rule, status], "❯ hello")
        check("a rule in the output, then a labelled box",
              ["output", rule, "more", labelled, "❯ hello", rule, status], "❯ hello")
        check("a bare shell", ["output", "❯ ls"], "❯ ls")
        check("prose with dashes is not a rule",
              ["output", "── see this ──> and that", "more", rule, "❯ ls"], "❯ ls")
        check("nothing to type on", ["output", "more"], nil)

        print(failed == 0 ? "  ✓ the input row (\(passed) cases)" : "  \(failed) failed, \(passed) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
