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
        // A rewrite erases what isBorder bounds.
        if SelectionReader.isBorder(labelled) || !SelectionReader.isBorder(rule) {
            failed += 1
            print("  ✗ isBorder takes a plain rule and not a labelled one")
        } else { passed += 1 }
        check("a prompt under an old box", [rule, "❯ old", rule, "output", "❯ ls"], "❯ ls")
        check("a menu glyph above the box", ["❯ 1. yes", rule, "❯ hello", rule, status], "❯ hello")
        check("a box cut off above", ["❯ hello", rule, status], "❯ hello")
        check("nothing to type on", ["output", "more"], nil)

        let emoji = "❯ 123456🙂 "
        let offset = SelectionReader.lastInputOffset(in: emoji, rows: 70) ?? -1
        let drawn = TerminalGrid.drawn(emoji, columns: 10, offset: offset)
        if drawn.all == 2, drawn.at == 0 { passed += 1 } else {
            failed += 1
            print("  ✗ an emoji before a space that wraps: got \(drawn), want (2, 0)")
        }

        print(failed == 0 ? "  ✓ the input row (\(passed) cases)" : "  \(failed) failed, \(passed) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
