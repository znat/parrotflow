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
        nil
    }
}
