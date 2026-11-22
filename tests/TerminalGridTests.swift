import Foundation

/// The numbers are readings from Ghostty 1.4.0 on 2026-11-22. Each `row` is the
/// cursor row the terminal itself answered to CSI 6n, from 1.
@main
enum TerminalGridTests {
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var passed = 0

    static func check<T: Equatable>(_ what: String, _ got: T, _ want: T) {
        if got == want { passed += 1; return }
        failed += 1
        print("  ✗ \(what): got \(got), want \(want)")
    }

    static let pane = CGSize(width: 2056, height: 1197)
    static let tty = TerminalGrid.Size(rows: 70, columns: 256, pixelWidth: 4104, pixelHeight: 2386)
    static let others = [
        TerminalGrid.Size(rows: 68, columns: 256, pixelWidth: 4104, pixelHeight: 2314),
        TerminalGrid.Size(rows: 49, columns: 254, pixelWidth: 4066, pixelHeight: 1688),
        TerminalGrid.Size(rows: 68, columns: 84, pixelWidth: 1352, pixelHeight: 2314),
    ]
    static let prompt = "❯ PFMARK"

    static func lines(_ count: Int) -> String { (0..<count).map { "line \($0)\n" }.joined() }

    static func row(_ text: String, content: CGFloat) -> Int? {
        let grid = TerminalGrid(pane: pane, content: content, scale: 2, ttys: others + [tty])
        let mark = (text as NSString).range(of: "PFMARK").location
        return grid?.row(atUTF16: mark, in: text).map { $0 + 1 }
    }

    static func main() {
        check("a fresh screen", row("one\ntwo\nthree\n" + prompt, content: 1197), 4)
        check("500 lines of history", row(lines(500) + prompt, content: 8524), 70)
        check("9000 lines of history", row(lines(9000) + prompt, content: 153_024), 70)
        check("blank rows below the prompt", row(lines(488) + prompt, content: 8524), 58)
        check("cleared, history kept", row(lines(431) + prompt, content: 8524), 1)
        check("the alternate screen", row(
            (0..<66).map { "a\($0)\n" }.joined() + prompt, content: 1197), 67)
        check("off screen, in the history", row(prompt + "\n" + lines(500), content: 8524), nil)

        let grid = TerminalGrid(pane: pane, content: 8524, scale: 2, ttys: [tty])
        check("row height", grid?.rowHeight, 17)
        check("padding", grid?.topPadding, 2)
        check("total rows", grid?.totalRows, 501)
        check("content that is not whole rows",
              TerminalGrid(pane: pane, content: 8530, scale: 2, ttys: [tty])?.totalRows, nil)
        check("no tty of this size", TerminalGrid.match(pane, scale: 2, in: others), nil)
        check("two ttys, one size, different fonts", TerminalGrid.match(
            pane, scale: 2, in: [tty, .init(rows: 80, columns: 290, pixelWidth: 4104, pixelHeight: 2386)]), nil)
        check("two ttys, one size, one font", TerminalGrid.match(pane, scale: 2, in: [tty, tty]), tty)

        let short = TerminalGrid.Size(rows: 10, columns: 256, pixelWidth: 4104, pixelHeight: 350)
        check("a short pane alone", TerminalGrid.rowHeights(of: short), [35, 34, 33, 32])
        check("a short pane takes the tallest pane's font", TerminalGrid(
            pane: CGSize(width: 2056, height: 179), content: 179, scale: 2, ttys: [short, tty])?.rowHeight, 17)

        func at(_ text: String, _ mark: String, columns: Int) -> [Int] {
            let got = TerminalGrid.drawn(
                text, columns: columns, offset: (text as NSString).range(of: mark).location)
            return [got.all, got.at ?? -1]
        }
        check("a wrapped line", at(String(repeating: "x", count: 25) + "\n@", "@", columns: 10), [4, 3])
        check("inside a wrapped line", at("0123456789abcdefghij@", "@", columns: 10), [3, 2])
        check("an exact fit does not wrap", at("0123456789\n@", "@", columns: 10), [2, 1])
        check("wide characters", at("日本語日本語\n@", "@", columns: 10), [3, 2])
        check("a wide character that does not fit", at("日本語日本\n@", "@", columns: 9), [3, 2])
        check("a rule is one column a character", at(
            String(repeating: "─", count: 10) + "\n@", "@", columns: 10), [2, 1])
        check("an emoji", at("🙂🙂🙂🙂🙂🙂\n@", "@", columns: 10), [3, 2])

        print(failed == 0 ? "  ✓ the terminal grid (\(passed) cases)" : "  \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
