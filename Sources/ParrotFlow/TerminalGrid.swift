import Darwin
import Foundation

/// A Ghostty pane's grid, which accessibility does not give.
///
/// Measured on Ghostty 1.4.0. `AXVisibleCharacterRange` is the whole content,
/// and `AXValue` joins soft wraps and drops the blank rows at the end. The
/// pane's tty has the rows and columns. `AXContentSize` of its scroll area is
/// every row, history included, times the row height, plus the padding.
struct TerminalGrid {

    /// What `TIOCGWINSZ` answers, in cells and device pixels.
    struct Size: Equatable {
        let rows: Int
        let columns: Int
        let width: Int
        let height: Int
    }

    let rows: Int
    let columns: Int
    /// Rows in the history and the screen, blank ones included.
    let total: Int
    /// Points.
    let cell: CGFloat
    /// Points above the first row.
    let padding: CGFloat

    /// Nil when the sizes do not agree with one another.
    init?(pane: CGSize, content: CGFloat, scale: CGFloat, ttys: [Size]) {
        guard scale > 0, let size = Self.match(pane, scale: scale, in: ttys) else { return nil }
        let history = ((content - pane.height) * scale).rounded()
        guard history >= 0 else { return nil }

        let fits = Self.cells(of: size).filter { Int(history) % $0 == 0 }
        // A short pane leaves more than one candidate. Panes of one app share a
        // font unless one was zoomed, so the tallest decides.
        let tallest = ttys.max { $0.rows < $1.rows }.map(Self.cells) ?? []
        guard let pixels = fits.first(where: { tallest.contains($0) }) ?? fits.first else { return nil }

        rows = size.rows
        columns = size.columns
        total = size.rows + Int(history) / pixels
        cell = CGFloat(pixels) / scale
        padding = max(0, (pane.height * scale - CGFloat(size.height)) / 2 / scale)
    }

    /// The row on screen, from 0, that a UTF-16 offset of the value is drawn on
    /// once the pane is scrolled to its end. Nil when it is in the history.
    func row(at offset: Int, in text: String) -> Int? {
        let (all, at) = Self.drawn(text, columns: columns, offset: offset)
        guard let at else { return nil }
        // A width counted wrong far up the history makes this negative.
        let blank = max(0, total - all)
        let row = rows - blank - (all - at)
        return (0..<rows).contains(row) ? row : nil
    }

    // MARK: - Parts

    /// The tty whose pixels are this pane's, less its padding. Ghostty's
    /// default padding is 2pt a side, 8 device pixels at scale 2.
    static func match(_ pane: CGSize, scale: CGFloat, in ttys: [Size]) -> Size? {
        let slack = 0...Int(20 * scale)
        let near = ttys.compactMap { tty -> (size: Size, off: Int)? in
            let dx = Int((pane.width * scale).rounded()) - tty.width
            let dy = Int((pane.height * scale).rounded()) - tty.height
            guard tty.rows > 0, tty.columns > 0, slack.contains(dx), slack.contains(dy) else { return nil }
            return (tty, dx + dy)
        }
        guard let best = near.min(by: { $0.off < $1.off }) else { return nil }
        let tied = near.filter { $0.off == best.off }
        return tied.allSatisfy { $0.size == best.size } ? best.size : nil
    }

    /// Row heights, in device pixels, that give this many rows.
    static func cells(of size: Size) -> [Int] {
        guard size.rows > 0 else { return [] }
        let high = size.height / size.rows
        let low = size.height / (size.rows + 1) + 1
        return low <= high ? Array((low...high).reversed()) : []
    }

    /// How many rows the text is drawn on, and which one the offset is on.
    ///
    /// Bytes, because `String.utf16` indexing took 26 ms on 9,000 lines of 80.
    static func drawn(_ text: String, columns: Int, offset: Int) -> (all: Int, at: Int?) {
        // Text from accessibility is a bridged string, slow to walk by UTF-8.
        var text = text
        text.makeContiguousUTF8()
        return text.withUTF8 { bytes in
            guard let target = byte(at: offset, in: bytes) else { return (0, nil) }
            var rows = 0
            var at: Int?
            var start = 0
            while start <= bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                let inside = at == nil && target <= end
                // UTF-8 bytes are never fewer than columns.
                if !inside, line.count <= columns {
                    rows += 1
                } else if !inside, line.allSatisfy({ $0 < 0x80 }) {
                    rows += (line.count + columns - 1) / columns
                } else {
                    let measured = wrapped(
                        String(bytes: line, encoding: .utf8) ?? "",
                        columns: columns, offset: target - start)
                    if inside { at = rows + measured.at }
                    rows += measured.rows
                }
                start = end + 1
            }
            return (rows, at)
        }
    }

    /// The byte a UTF-16 offset falls on.
    private static func byte(at offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var units = 0
        for index in bytes.indices {
            if units >= offset, bytes[index] & 0xC0 != 0x80 { return index }
            units += self.units(of: bytes[index])
        }
        return units >= offset ? bytes.count : nil
    }

    /// The UTF-16 units a UTF-8 byte adds: none inside a character, two for the
    /// first byte of one past U+FFFF.
    static func units(of byte: UInt8) -> Int {
        byte & 0xC0 == 0x80 ? 0 : byte >= 0xF0 ? 2 : 1
    }

    private static func wrapped(
        _ line: String, columns: Int, offset: Int
    ) -> (rows: Int, at: Int) {
        var row = 0, column = 0, bytes = 0, at = 0
        for character in line {
            let wide = width(of: character)
            if column + wide > columns { row += 1; column = 0 }
            column += wide
            if bytes <= offset { at = row }
            bytes += character.utf8.count
        }
        return (row + 1, at)
    }

    /// Columns a character takes. `wcwidth` depends on the locale, and a bundled
    /// app runs in C, where it knows ASCII only.
    private static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.value < 0x300 { return 1 }
        if character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x3FFFD:
            return 2
        default:
            return scalar.properties.isEmojiPresentation ? 2 : 1
        }
    }

    // MARK: - The ttys

    /// The window size of every tty an app's children run on. Its children are
    /// `login`, which is root's, so `proc_pidinfo` refuses them and `sysctl`
    /// does not.
    static func ttys(of app: pid_t) -> [Size] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var bytes = 0
        guard sysctl(&mib, 4, nil, &bytes, nil, 0) == 0 else { return [] }
        // Processes can start between the two calls.
        bytes += bytes / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: bytes / stride)
        bytes = list.count * stride
        guard sysctl(&mib, 4, &list, &bytes, nil, 0) == 0 else { return [] }

        var seen = Set<dev_t>()
        return list.prefix(bytes / stride).compactMap { process in
            let device = process.kp_eproc.e_tdev
            guard process.kp_eproc.e_ppid == app, device != -1, device != 0,
                  seen.insert(device).inserted, let name = devname(device, S_IFCHR)
            else { return nil }
            let file = open("/dev/" + String(cString: name), O_RDONLY | O_NOCTTY | O_NONBLOCK)
            guard file >= 0 else { return nil }
            defer { close(file) }
            var size = winsize()
            guard ioctl(file, TIOCGWINSZ, &size) == 0 else { return nil }
            return Size(rows: Int(size.ws_row), columns: Int(size.ws_col),
                        width: Int(size.ws_xpixel), height: Int(size.ws_ypixel))
        }
    }
}
