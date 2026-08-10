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
/// detects a screen reader.
///
/// ## The apps that give no caret
///
/// For those, `read(at:)` misses and the answer is found the other way round.
/// `snapshot(of:)` takes the pane's text at the press, `landed(after:at:)`
/// compares it with the pane after the words arrive, and the difference between
/// the two is where they went. That runs after the insertion, so it moves a
/// pill that is already on screen rather than deciding where one opens.
///
/// It is a diff and not a search, and that is what makes it work at all. See
/// `landed(after:at:)`.
enum CaretAnchor {

    /// Which rung answered. Logged, because "the pill opened in the wrong
    /// place" is a different bug for each of these.
    enum Source: String {
        /// The app gave the rectangle of its caret, at the press.
        case caret
        /// The focused control's own rectangle — only taken when the control is
        /// small enough that its box and its caret mean the same thing.
        case field
        /// Worked out afterwards, from what changed on screen. For the apps
        /// that have no caret to give — see `landed(after:at:)`.
        case landed
        /// Where the last dictation into this same element ended up. A guess,
        /// and the only thing available at the press for an app with no caret.
        case remembered
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

    /// For the reads that happen after the dictation instead of inside the
    /// key-down handler.
    ///
    /// Longer because nothing is waiting on them and the value being copied is
    /// large: Outlook's message pane measured 395,489 characters, and every
    /// look copies all of them out of a busy process.
    private static let unhurriedTimeout: Float = 0.5

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

    /// How many characters the element holds.
    ///
    /// One number rather than the text, so it is cheap enough to ask inside the
    /// key-down handler. The value itself has been seen at 395,489 characters
    /// and copying that would delay the recording.
    ///
    /// This is what tells a remembered anchor from a stale one. It changes the
    /// moment anything is printed into the pane, which is exactly when last
    /// time's row stops belonging to last time's words.
    static func characterCount(of element: AXUIElement?) -> Int? {
        guard let element else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &value
        ) == .success, let count = value as? Int else { return nil }
        return count
    }

    // MARK: - Apps with no caret, found afterwards

    /// The pane's text as it was before a word of this was said.
    ///
    /// Only worth taking for an app that would not give a caret, and only ever
    /// off the main thread: see `unhurriedTimeout` for the size of the thing
    /// being copied.
    static func snapshot(of element: AXUIElement?) -> String? {
        guard let element else { return nil }
        AXUIElementSetMessagingTimeout(element, unhurriedTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        ) == .success, let text = value as? String, !text.isEmpty
        else { return nil }
        return text
    }

    /// Where the words landed, by comparing the pane with how it was.
    ///
    /// A diff and not a search, and that is the difference between this working
    /// and not. The first version looked for the transcript in the field. That
    /// fails whenever what was written is not what was transcribed, and a
    /// pipeline stage rewriting the sentence between the two is normal. It also
    /// fails when the text is there but not as one string: a value is what is
    /// *rendered*, so a wrapped sentence has a newline through the middle of it
    /// and a terminal drawing an input box pads it with spaces. Nothing has to
    /// match a diff. What changed is where the words are.
    ///
    /// Bounded at both ends, because a terminal is not a text field. A spinner
    /// or a clock ticking above would poison a common prefix on its own, so
    /// take the common suffix too and the change sits between two fixed points.
    /// A change spanning more than half the pane is a repaint rather than an
    /// insertion, and is refused.
    ///
    /// Runs after the insertion, so it is off the main thread and unhurried.
    static func landed(after before: String, at element: AXUIElement?) -> Outcome {
        guard let element else { return .missed("the element is gone") }
        // For every read below, the snapshot included.
        AXUIElementSetMessagingTimeout(element, unhurriedTimeout)

        guard let now = snapshot(of: element) else { return .missed("no text to compare") }
        guard now != before else { return .missed("the screen has not changed yet") }

        // UTF-16, because that is the unit an accessibility range counts in.
        // The indices found here are handed straight back to the app.
        let old = Array(before.utf16), new = Array(now.utf16)
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        let length = new.count - head - tail
        guard length > 0 else { return .missed("the screen changed, but nothing was added") }
        guard length < new.count / 2 else { return .missed("the whole pane repainted") }

        let pane = frame(of: element).map(flipped)

        // There is an index now, so ask the app where it is. An app can keep no
        // caret and still measure text perfectly well — Outlook does — and the
        // two failings are unrelated: one is about tracking a cursor, the other
        // about measuring text. Asked with a range of our own, the app that
        // would not say where the caret was says exactly where the words are.
        if let rect = bounds(of: CFRange(location: head, length: length), in: element) {
            let text = flipped(rect)
            return .found(Found(rect: across(text, pane), text: text, source: .landed))
        }

        // No bounds, so work out the row instead. A terminal is a fixed grid,
        // so the pane's height over the number of rows it shows is the pitch,
        // and the row is all that is left to find.
        guard let pane else { return .missed("no geometry") }
        guard let row = line(of: head, in: element),
              let grid = visibleGrid(of: element, holding: new.count)
        else { return .missed("no bounds, and it will not say which line an index is on") }

        // Every row the pane shows, not every row that has text on it. A pitch
        // is a line height and it has a range: 17.3pt was measured on Ghostty,
        // and an answer far outside that came from counting the wrong rows.
        // Refused rather than used, which is the rule everywhere else here —
        // the pill stays where it opened, and nowhere in particular beats
        // somewhere wrong.
        let pitch = pane.height / CGFloat(grid.rows)
        guard (6.0...40.0).contains(pitch), (grid.first..<grid.first + grid.rows).contains(row)
        else {
            return .missed(String(
                format: "the grid says row %d of %d at %.0fpt, which is not a line of text",
                row, grid.rows, pitch
            ))
        }

        // The grid gives a row and no column — see `across` for why the column
        // would be thrown away anyway. So the row is the whole width of the
        // pane, and it is both rectangles: there is no narrower one to pick the
        // display from, and a row of a pane straddling two monitors goes to
        // whichever shows more of it.
        //
        // Built in flipped coordinates, where `maxY` is the pane's top edge, so
        // rows count downward from there.
        let rect = NSRect(
            x: pane.minX, y: pane.maxY - CGFloat(row - grid.first + 1) * pitch,
            width: pane.width, height: pitch
        )
        return .found(Found(rect: rect, text: rect, source: .landed))
    }

    /// The rows the pane is showing: the first one, and how many.
    ///
    /// `AXVisibleCharacterRange` is what is on screen, so the lines it spans
    /// are the rows on screen. Asked first because it is the only answer that
    /// is about the viewport rather than about the text — and it also gives the
    /// row the top of the pane is showing, which a row index has to be counted
    /// from when the value carries scrollback above it.
    ///
    /// Without it, the value's own last line is all there is to go on. That is
    /// only the viewport if the app reports its blank rows too: Ghostty does,
    /// and 53 rows over a 917pt pane is 17.3pt, a real line height rather than
    /// a fit. An app that stopped at the last written line would report too few
    /// rows and the pitch would come out too large — which is why the caller
    /// checks the pitch instead of trusting it.
    private static func visibleGrid(of element: AXUIElement, holding count: Int) -> (first: Int, rows: Int)? {
        if let visible = range(kAXVisibleCharacterRangeAttribute, of: element), visible.length > 0,
           let first = line(of: visible.location, in: element),
           let last = line(of: visible.location + visible.length - 1, in: element),
           last >= first {
            return (first, last - first + 1)
        }
        guard count > 0, let last = line(of: count - 1, in: element) else { return nil }
        return (0, last + 1)
    }

    /// Which row of the grid an index sits on. Nil when the app will not say.
    private static func line(of index: Int, in element: AXUIElement) -> Int? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: index), &out
        ) == .success, let value = out as? NSNumber else { return nil }
        return value.intValue >= 0 ? value.intValue : nil
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
        range(kAXSelectedTextRangeAttribute, of: element)
    }

    /// Any attribute whose value is a range.
    private static func range(_ attribute: String, of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value
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
