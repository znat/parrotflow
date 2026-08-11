import AppKit
import ApplicationServices

/// Where the words are about to go, read at the moment the key goes down.
///
/// The pill then opens there instead of at the bottom of the screen, so the
/// first thing a dictation does is point at the place it is going to land.
///
/// ## Why at the press and not at the end
///
/// An earlier version read this when the transcript had been inserted, and
/// found the words by searching the field for them. It worked about half the
/// time. The reason is not accessibility being unreliable — it is that the
/// question was asked at the worst possible moment. The offer is raised the
/// instant the insertion returns, and an app redraws when it gets round to it,
/// so half the time the words were not on screen yet to be found. Everything
/// built on top of that — a 120ms retry, matching progressively shorter tails
/// of the sentence — was scaffolding around a race.
///
/// At key-down there is no race. Nothing has been inserted, nothing is
/// redrawing, and the caret is sitting exactly where the words are going to
/// start. The same question asked here is simply answered.
///
/// ## What the system will actually tell us
///
/// Measured on one Mac, five apps, asking for the bounds of the selected range:
///
///     iTerm2         7x17, one character cell
///     Terminal.app   546x14, the whole line
///     Notes          466x16, the whole line
///     Ghostty        no bounds, and its selected range is 0 whatever the
///                    caret is doing — so there is nothing to place
///     VS Code        no focused element at all, only a window
///
/// Three of five, and the two that do not answer cannot be made to: Ghostty has
/// no caret to report and VS Code builds no accessibility tree unless it
/// detects a screen reader. Where this returns nothing the pill opens where it
/// always has, which is the whole of the fallback.
enum CaretAnchor {

    /// Which rung answered. Logged, because "the pill opened in the wrong
    /// place" is a different bug for each of these.
    enum Source: String {
        /// The app gave the rectangle of its caret, at the press.
        case caret
        /// The focused control's own rectangle — only taken when the control is
        /// small enough that its box and its caret mean the same thing.
        case field
    }

    struct Found {
        /// Where the pill goes: the caret's row, the pane's left edge and
        /// width. See `across`.
        ///
        /// In Cocoa screen coordinates — origin bottom-left, y upward. The
        /// accessibility API works top-left with y downward, and the flip
        /// happens here so no caller has to remember it.
        let rect: NSRect
        /// The text's own rectangle, before the column was taken from the pane.
        ///
        /// Which display the pill belongs on is decided from this and not from
        /// `rect`: a pane can straddle two monitors, the caret is only ever on
        /// one of them, and the wider rectangle can have most of its area on
        /// the monitor the words are not on. Same coordinates as `rect`.
        let text: NSRect
        let source: Source
    }

    enum Outcome {
        case found(Found)
        case missed(String)
    }

    /// Short, because this runs inside the key-down handler.
    ///
    /// The one thing that handler may not do is delay the recording. The
    /// element has already been resolved and read from by the selection
    /// snapshot a few lines above the call, so an app that is going to answer
    /// has answered by now; this cap is for the app that is not.
    private static let timeout: Float = 0.08

    /// Where the caret is, for the element focus was on when the key went down.
    static func read(at element: AXUIElement?) -> Outcome {
        guard Permissions.accessibility == .granted else {
            return .missed("accessibility is not granted")
        }
        guard let element else { return .missed("nothing was focused") }
        guard !SelectionReader.isOurs(element) else { return .missed("our own window") }
        AXUIElementSetMessagingTimeout(element, timeout)

        let pane = frame(of: element)

        if let selection = selectedRange(of: element), trust(selection, in: element),
           let rect = bounds(of: selection, in: element) {
            let text = flipped(rect)
            return .found(Found(
                rect: across(text, pane.map(flipped)), text: text, source: .caret
            ))
        }

        // The control's own rectangle, but only when it is small enough to be
        // one. A search box is 22pt tall and its box is as good as its caret; a
        // terminal's text view is 915pt tall and its box puts the pill under
        // the *window*, halfway down the screen — a third place for the pill to
        // be, and less predictable than either of the other two.
        if let pane, pane.height <= 120 {
            // The box is standing in for the caret, so it is both.
            let box = flipped(pane)
            return .found(Found(rect: box, text: box, source: .field))
        }
        return .missed(pane == nil ? "no geometry" : "no caret, and the pane is too big to stand in for one")
    }

    // MARK: - The questions

    /// Whether a reported range is a caret or a value nobody is maintaining.
    ///
    /// Some apps implement `AXSelectedTextRange` by returning the *selection*
    /// and leaving it empty when there is none — so the answer is `0` wherever
    /// the caret actually is. Believed, that puts the pill at the first
    /// character of the document and calls it the caret, which is worse than
    /// having no anchor: it is confidently wrong, and it stops anything else
    /// from being tried.
    ///
    /// Measured: Outlook reports `0+0` in a text area holding 395,489
    /// characters, and Ghostty reports `0+0` always. Meanwhile iTerm2 reported
    /// 163, Terminal.app 479 and Notes 232 with far less text in them.
    ///
    /// So: zero, in a field with real content in it, is not a caret. A document
    /// whose caret genuinely sits at the start is the false negative, and it
    /// costs nothing — the pill opens at the bottom of the screen, which is
    /// where it opened before any of this.
    private static func trust(_ range: CFRange, in element: AXUIElement) -> Bool {
        guard range.location == 0, range.length == 0 else { return true }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &value
        ) == .success, let count = value as? Int else { return true }
        return count < 200
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let wrapped = value, CFGetTypeID(wrapped) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(wrapped as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        // Length is never zero: some apps answer an empty rect for a collapsed
        // range and a real one for a character, and an empty rect cannot be
        // told apart from a refusal.
        var asked = CFRange(location: range.location, length: max(1, range.length))
        guard let parameter = AXValueCreate(.cfRange, &asked) else { return nil }

        var box: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &box
        ) == .success, let value = box, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect),
              rect.width > 0 || rect.height > 0
        else { return nil }
        return rect
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        var position: CFTypeRef?
        var extent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString, &extent) == .success,
              let positionValue = position, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let extentValue = extent, CFGetTypeID(extentValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(extentValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Helpers

    /// The row from the caret, the left edge from the pane it is in.
    ///
    /// The column is deliberately thrown away. What an app returns for a range
    /// is one character in iTerm2 and a whole line in Terminal.app, so the same
    /// call means different things in different apps, and lining the pill up
    /// with any of them put it in a place that moved for reasons invisible from
    /// outside — correct every time, arbitrary-looking every time. The left
    /// edge of the pane does not move. It is not where the caret is, and it is
    /// the same place on every dictation, which is the property that matters
    /// for a surface you glance at.
    ///
    /// Both rectangles are already flipped, and flipping only moves y, so
    /// widening before the flip and after it give the same answer.
    private static func across(_ rect: NSRect, _ pane: NSRect?) -> NSRect {
        guard let pane else { return rect }
        return NSRect(x: pane.minX, y: rect.minY, width: pane.width, height: rect.height)
    }

    /// Accessibility measures from the top-left of the primary display with y
    /// growing downward; `NSWindow` measures from its bottom-left with y
    /// growing upward. Everything above this line is in the first system and
    /// everything outside this file is in the second.
    private static func flipped(_ rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return NSRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
