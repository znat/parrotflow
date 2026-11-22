import Foundation

/// Which row of a terminal's text is being typed on.
extension SelectionReader {

    /// The UTF-16 index of the row being typed on.
    ///
    /// Inside the box a TUI drew, or the shell prompt when nothing drew one.
    /// `CaretAnchor` turns it into a grid row, and a row into somewhere to open
    /// the pill.
    static func lastInputRowIndex(in screen: String) -> Int? {
        let rows = screen.components(separatedBy: "\n")
        guard let last = inputRowNumber(in: rows) else { return nil }
        // +1 per row for the newline that separated it.
        return rows[0..<last].reduce(0) { $0 + $1.utf16.count + 1 }
    }

    /// The UTF-16 offset of the last character typed on the input line, looking
    /// only at the lines that can be on a screen of `rows` rows.
    static func lastInputOffset(in screen: String, rows: Int) -> Int? {
        var screen = screen
        let (above, tail) = screen.withUTF8 { bytes -> (Int, String) in
            var start = bytes.count
            var breaks = 0
            while start > 0 {
                if bytes[start - 1] == 0x0A {
                    breaks += 1
                    if breaks == rows { break }
                }
                start -= 1
            }
            return (bytes[..<start].reduce(0) { $0 + TerminalGrid.units(of: $1) },
                    String(bytes: bytes[start...], encoding: .utf8) ?? "")
        }
        let lines = tail.components(separatedBy: "\n")
        guard let last = inputRowNumber(in: lines) else { return nil }
        let before = lines[..<last].reduce(0) { $0 + $1.utf16.count + 1 }
        let typed = lines[last].reversed().drop { $0 == " " }
            .reduce(0) { $0 + String($1).utf16.count }
        return above + before + max(0, typed - 1)
    }

    private static func inputRowNumber(in rows: [String]) -> Int? {
        let borders = rows.indices.filter { isBorder(rows[$0]) }
        if borders.count >= 2 {
            let lower = borders[borders.count - 1]
            let upper = borders[borders.count - 2]
            if upper + 1 < lower {
                // The last row inside the box with anything on it. A box is
                // drawn its full height whatever is typed into it, so the
                // bottom row is padding and anchoring there sits below the box.
                return (upper + 1..<lower).last {
                    !rows[$0].trimmingCharacters(in: .whitespaces).isEmpty
                } ?? upper + 1
            }
        }
        // No box, so a bare shell. By the prompt glyph rather than the last row
        // with text on it, because a status bar sits below the shell and under
        // tmux it is always the last thing on screen.
        return rows.indices.reversed().first {
            guard let first = rows[$0].drop(while: { $0 == " " }).first else { return false }
            return "❯>$#%⏵".contains(first)
        }
    }

    /// A rule the TUI drew, rather than anything anyone typed.
    static func isBorder(_ row: String) -> Bool {
        let bare = row.trimmingCharacters(in: .whitespaces)
        return !bare.isEmpty && bare.allSatisfy { "─━—-│┃|┌┐└┘├┤╭╮╰╯╌┄".contains($0) }
    }
}
