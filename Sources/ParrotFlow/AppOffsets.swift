import Foundation

/// Places text the app names in its own offsets into its `AXValue`.
///
/// Chromium counts no character between two adjacent paragraphs in
/// `AXSelectedTextRange`, `AXSelectedText` and `AXStringForRange`, while
/// `AXValue` puts a "\n" there. Measured on Chrome 154 and Electron 44: three
/// paragraphs, all selected, read 340 in the app's offsets and 342 in the value.
enum AppOffsets {

    /// Where `selected` sits in `value`, given `before`, the app's own text from
    /// its offset 0 up to the selection. Both are walked from the start, and the
    /// only thing skipped is a "\n" the value has and the app does not, so the
    /// answer is one place and never a second copy further on. Nil when
    /// anything else differs.
    static func valueRange(
        before: String, selected: String, in value: String
    ) -> Range<String.Index>? {
        guard !selected.isEmpty else { return nil }
        let units = Array(value.utf16)
        let newline: UInt16 = 0x0A
        var at = 0

        func consume(_ text: String) -> Int? {
            var first: Int?
            for unit in text.utf16 {
                while at < units.count, units[at] != unit, units[at] == newline { at += 1 }
                guard at < units.count, units[at] == unit else { return nil }
                if first == nil { first = at }
                at += 1
            }
            return first ?? at
        }

        guard consume(before) != nil, let start = consume(selected) else { return nil }
        return Range(NSRange(location: start, length: at - start), in: value)
    }
}
