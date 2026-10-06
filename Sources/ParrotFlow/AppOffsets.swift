import Foundation

/// Translates between the app's own offsets and its `AXValue`.
///
/// Chromium counts no character between two adjacent paragraphs in
/// `AXSelectedTextRange`, `AXSelectedText` and `AXStringForRange`, while
/// `AXValue` puts a "\n" there. Measured on Chrome 154 and Electron 44: three
/// paragraphs, all selected, read 340 in the app's offsets and 342 in the value.
enum AppOffsets {

    /// Where `selected` sits in `value`, given `before`, the app's own text from
    /// its offset 0 up to the selection. Nil when anything but such a "\n"
    /// differs.
    static func valueRange(
        before: String, selected: String, in value: String
    ) -> Range<String.Index>? {
        let start = before.utf16.count
        let end = start + selected.utf16.count
        guard end > start, let at = positions(of: before + selected, in: value) else { return nil }
        return Range(NSRange(location: at[start], length: at[end] - at[start]), in: value)
    }

    /// `range`, an NSRange of `value`, in the app's offsets. `app` is the app's
    /// own text from its offset 0, at least as far as the range reaches.
    static func appRange(of range: NSRange, app: String, in value: String) -> NSRange? {
        guard let at = positions(of: app, in: value) else { return nil }
        let count = at.count - 1
        func appOffset(_ offset: Int) -> Int { at.prefix(count).firstIndex { $0 >= offset } ?? count }
        let start = appOffset(range.location)
        return NSRange(location: start, length: appOffset(NSMaxRange(range)) - start)
    }

    /// For each UTF-16 unit of `app`, its offset in `value`, then the offset
    /// after the last one. Both are walked from the start, and the only thing
    /// skipped is a "\n" the value has and the app does not, so each unit lands
    /// in one place and never on a second copy further on.
    private static func positions(of app: String, in value: String) -> [Int]? {
        let units = Array(value.utf16)
        let newline: UInt16 = 0x0A
        var at = 0
        var found: [Int] = []
        found.reserveCapacity(app.utf16.count + 1)
        for unit in app.utf16 {
            while at < units.count, units[at] != unit, units[at] == newline { at += 1 }
            guard at < units.count, units[at] == unit else { return nil }
            found.append(at)
            at += 1
        }
        found.append(at)
        return found
    }

    /// `selected`, which the app reads at `location` in its own offsets, as
    /// `value` shows it. `before` is the app's text from 0 to `location`.
    static func shown(
        _ selected: String, at location: Int, in value: String, before: () -> String?
    ) -> String {
        if let range = Range(NSRange(location: location, length: selected.utf16.count), in: value),
           value[range] == selected {
            return selected
        }
        guard let before = before(),
              let range = valueRange(before: before, selected: selected, in: value)
        else { return selected }
        return String(value[range])
    }

    /// `paragraphs` joined by line breaks, when that is `text` with only line
    /// breaks added. Chromium reads an empty paragraph between two others as
    /// one "\n" in every string it gives; its paragraph children keep it.
    static func withBlankLines(_ text: String, paragraphs: [String]) -> String {
        let joined = paragraphs.joined(separator: "\n")
        guard !text.isEmpty, let at = positions(of: text, in: joined) else { return text }
        let units = Array(joined.utf16)
        let newline: UInt16 = 0x0A
        guard units[..<at[0]].allSatisfy({ $0 == newline }),
              units[at[at.count - 1]...].allSatisfy({ $0 == newline }) else { return text }
        return joined
    }
}
