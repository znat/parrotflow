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
        /// The bottom of the app's own window, for an app that answers
        /// nothing. A guess: their composer sits at the bottom.
        case window
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

    /// One budget for a whole lookup, rather than one per request.
    ///
    /// `AXUIElementSetMessagingTimeout` caps a single request.
    /// `inputBox` makes seven in a row, so seven 80ms caps is 560ms — spent
    /// before the recorder has started, on words somebody is already saying.
    /// Armed before each request with what is left, the lookup cannot outlast
    /// the budget.
    private struct Deadline {
        private let at: Date
        init(_ seconds: Float) { at = Date().addingTimeInterval(TimeInterval(seconds)) }

        /// Puts what is left on the element. False when it is spent.
        func arm(_ element: AXUIElement) -> Bool {
            let left = Float(at.timeIntervalSinceNow)
            guard left > 0.005 else { return false }
            AXUIElementSetMessagingTimeout(element, left)
            return true
        }
    }

    /// Short, because this runs inside the key-down handler.
    ///
    /// The one thing that handler may not do is delay the recording. The
    /// element has already been resolved and read from by the selection
    /// snapshot a few lines above the call, so an app that is going to answer
    /// has answered by now; this cap is for the app that is not.
    private static let timeout: Float = 0.08

    /// How many lines of the value may sit below where the change starts.
    ///
    /// This is what an insertion looks like from outside: it happens at the
    /// end of the buffer, because that is where a prompt is. What is under the
    /// caret while you type is the rest of the input area and whatever the
    /// program draws beneath it — Claude Code's input box grows to about six
    /// lines as you type into it, with a border under that and a mode line and
    /// a status line under that, which is nine. Twelve leaves room for a
    /// program that draws one more.
    ///
    /// It is nothing beside the thing being excluded. A scroll changes the
    /// first line of the value and every line after it, and a full repaint the
    /// same, so both cover hundreds of lines rather than twelve.
    ///
    /// The same number answers both questions the diff asks — how many lines
    /// the change covers, and how many written lines are below it — because
    /// both are asking the same thing about the same object: how big an input
    /// area and the furniture around it can be.
    private static let promptLines = 12

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

        // Chromium and Outlook both get past the line above without answering.
        // `AXBoundsForRange` declines inside a contenteditable, and Outlook
        // reports its selection as `0+0`, which `trust` refuses. A composer is
        // far taller than the 120pt below, so nothing was left and the pill
        // opened at the bottom of the screen.
        //
        // The markers a screen reader reads text through do answer. Measured
        // 2026-08-28: a Gmail composer gave 1613,631 0x15 — no width, one line
        // tall, which is a caret — where the text leaf beside it ran
        // 1293,631 320x15, so 1293 plus 320 lands exactly at the end of what
        // had been typed. On that same element `AXBoundsForRange` answered
        // 0,1329 0x0. Outlook answered 826,964 with a height of 19.
        //
        // Slack answers the pair too and gives a 0x0 rect a screen away, so
        // this is checked twice: a caret has a height and that answer has none,
        // and a rect a screen away is not inside the pane.
        if let rect = markerCaret(of: element), (4.0...100.0).contains(rect.height),
           let pane, pane.insetBy(dx: -4, dy: -4).intersects(rect) {
            let text = flipped(rect)
            return .found(Found(rect: across(text, flipped(pane)), text: text, source: .caret))
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

    /// The caret's rectangle, asked for the way a screen reader asks.
    ///
    /// Two private attributes, which is what a text area answers when the
    /// public range ones decline. See `read` for what each app said.
    private static func markerCaret(of element: AXUIElement) -> CGRect? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &marker
        ) == .success, let marker else { return nil }

        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, marker, &out
        ) == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Where the input line is, for a terminal that will not say where its
    /// caret is.
    ///
    /// Ghostty answers `AXSelectedTextRange` as `0+0` always, so `read` misses,
    /// and a terminal repaints between dictations so the remembered rung is
    /// refused too. The pill opened at the bottom of the screen and moved only
    /// once the words had landed, which is the placement that reads as random.
    ///
    /// No caret is needed to find the line: it is the row inside the rules a
    /// TUI draws, or the shell prompt when nothing drew any.
    static func inputBox(at element: AXUIElement?) -> Outcome {
        guard Permissions.accessibility == .granted else {
            return .missed("accessibility is not granted")
        }
        guard let element else { return .missed("nothing was focused") }
        guard !SelectionReader.isOurs(element) else { return .missed("our own window") }

        // Seven requests, one budget. See `Deadline`.
        let deadline = Deadline(timeout)

        guard let pane = frame(of: element, before: deadline).map(flipped) else {
            return .missed("no geometry, or the budget ran out")
        }
        guard deadline.arm(element),
              let screen = SelectionReader.visibleText(of: element, within: nil)
        else { return .missed("the terminal will not say what is on screen in time") }

        guard let index = SelectionReader.lastInputRowIndex(in: screen) else {
            return .missed("nothing on screen looks like an input line")
        }
        guard let row = line(of: index, in: element, before: deadline),
              let grid = visibleGrid(of: element, before: deadline)
        else { return .missed("it will not say how the grid is laid out in time") }
        return rectangle(forRow: row, of: grid, in: pane, source: .landed)
    }

    /// The bottom strip of an app's frontmost window, for apps that answer no
    /// accessibility questions.
    ///
    /// Read from the window server, which cannot be refused by the app —
    /// asking these apps for a window through AX fails as asking for a caret
    /// does.
    ///
    /// Centred rather than full width because `beside` puts the pill at its
    /// anchor's left edge, which would park it against the window frame.
    static func window(of pid: pid_t) -> Found? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let listed = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // Layer order, so the app's first entry is its frontmost window.
        let mine = listed.first { entry in
            (entry[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (entry[kCGWindowLayer as String] as? Int) == 0
                && (entry[kCGWindowBounds as String] as? [String: CGFloat]).map {
                    ($0["Width"] ?? 0) > 200 && ($0["Height"] ?? 0) > 200
                } == true
        }
        guard let bounds = mine?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }

        // `kCGWindowBounds` is top-left with y downward, like the AX API.
        let strip = flipped(
            CGRect(x: x + width / 4, y: y + height - 96, width: width / 2, height: 44)
        )
        return Found(rect: strip, text: strip, source: .window)
    }

    /// A fingerprint of what the pane is showing, read at the press.
    ///
    /// This is what tells a remembered anchor from a stale one, and it has to
    /// be the text because the cheap number is about something else.
    /// `AXNumberOfCharacters` was tried and is wrong here: measured on Ghostty
    /// it answers 49,842 and does not move while eight lines of output are
    /// printed, with `AXValue` at 2,082 over the same two reads. The count is
    /// the scrollback and the value is the screen, and only a resize changes
    /// the first. Compared against, it can never fail — so in the one app the
    /// `remembered` rung exists for, the guard was not a guard.
    ///
    /// Hashed rather than kept, because this is a staleness check and the
    /// question is only "the same as last time". It is compared within one run
    /// of the app, which is the only place a `hashValue` means anything.
    ///
    /// Reading the value at key-down is the thing that handler is told never to
    /// do, and it is allowed here for two reasons: it is capped at the same
    /// 80ms as everything else `read(at:)` asks, and it is only asked when
    /// there is a landing for this exact element to check — which is the rung
    /// below a caret, so the apps with one never pay for it.
    ///
    /// Not answering inside the cap means refusing the anchor, and that is
    /// right rather than merely safe. A pane too big to read in 80ms is
    /// Outlook's, and Outlook's pane scrolls too: a remembered rectangle there
    /// is worth no more than one in a terminal.
    static func paneDigest(of element: AXUIElement?) -> Int? {
        guard let element else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        ) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text.hashValue
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
    ///
    /// That gives one contiguous span, and the span is taken only when it is
    /// certainly an insertion: it has to start within `promptLines` of the end
    /// of the value. Anything else is refused, and refused means the pill stays
    /// at the bottom of the screen — which is the rule the whole rung answers
    /// to. If it moves it has to move to the right place, and it must never
    /// come to rest over the words being edited.
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

        // Two questions about the span, and it has to answer both. See
        // `promptLines` for the number, which is the same in each because both
        // are asking how big an input area and its furniture can be.
        //
        // The rule this replaces was that a span covering more than half the
        // value is a repaint. It refused the case it exists for: paste two
        // words into Claude Code's input box and the box, the mode line and
        // the status line all redraw, so the span runs from the box down to the
        // bottom of the pane — and in a small pane that is more than half of
        // it. Measured, the log said "the whole pane repainted", and it said it
        // more often the taller the input box had grown, which is a bigger
        // redraw and not a different kind of one. Size was the wrong question.
        //
        // How many lines it covers. An insertion is a line or a few, even when
        // a program redraws its whole input area around it. A scroll changes
        // every line there is, and so does a repaint, and neither is somewhere
        // to put the pill.
        let changed = new[head..<(new.count - tail)]
        var spanned = 1
        for unit in changed where unit == 0x0A { spanned += 1 }
        guard spanned <= promptLines else {
            return .missed("the change covers \(spanned) lines, which is a repaint and not an insertion")
        }

        // And whether it is at the end of what has been written. This is what
        // stops the pill going to a clock or a spinner that ticked while the
        // app had not redrawn yet: that is a small contiguous change too, and
        // the only thing that tells it apart from a dictation is where it is.
        //
        // Blank lines do not count towards the distance. They are what a
        // terminal pads its viewport with — a prompt in a pane with no history
        // sits above a screenful of them, which is where the 53 rows in
        // `visibleGrid` came from — so counting them would put every fresh pane
        // a screen away from its own end.
        let below = contentLines(in: new[(new.count - tail)...])
        guard below <= promptLines else {
            return .missed("the change ends \(below) lines above the last written one, so it is not at a prompt")
        }

        let pane = frame(of: element).map(flipped)

        // There is an index now, so ask the app where it is. An app can keep no
        // caret and still measure text perfectly well — Outlook does — and the
        // two failings are unrelated: one is about tracking a cursor, the other
        // about measuring text. Asked with a range of our own, the app that
        // would not say where the caret was says exactly where the words are.
        //
        // A span over several lines comes back as one rectangle covering all of
        // them, and that is what is wanted. `flipped` puts its Cocoa `minY` at
        // the bottom of the span, `across` keeps that edge, and `beside` opens
        // the pill below `minY` — so the pill clears the whole insertion and
        // not just the line it started on. Nothing to do here; it is written
        // down because the arithmetic is invisible and the grid below had to be
        // fixed for exactly this.
        if let rect = bounds(of: CFRange(location: head, length: length), in: element) {
            let text = flipped(rect)
            return .found(Found(rect: across(text, pane), text: text, source: .landed))
        }

        // No bounds, so work out the row instead. A terminal is a fixed grid,
        // so the pane's height over the number of rows it shows is the pitch,
        // and the row is all that is left to find.
        guard let pane else { return .missed("no geometry") }

        // The row the change *ends* on, not the one it starts on. A dictation
        // long enough to wrap covers two or three rows, and anchored to the
        // first the pill came to rest on top of the rest of it — which is the
        // one thing this rung must never do. Below the last row is below all of
        // them, and it is also where the caret has ended up, so it is the right
        // answer for its own reasons and not only for that bug.
        guard let row = line(of: head + length - 1, in: element),
              let grid = visibleGrid(of: element)
        else { return .missed("no bounds, and it will not say how the grid is laid out") }

        return rectangle(forRow: row, of: grid, in: pane, source: .landed)
    }

    /// A grid row as a rectangle on screen.
    /// Checked, not trusted. A pitch is a line height and it has a range, and
    /// the row has to be one the pane is showing. Either failing means the grid
    /// was read wrong, and a grid read wrong is refused rather than used: the
    /// pill stays where it opened, and nowhere in particular beats somewhere
    /// wrong.
    ///
    /// The band is 12 to 34pt. Measured: 17.3 and 17.26 on Ghostty, both sound.
    /// Against that, a pane carrying scrollback answered 109 rows where the
    /// terminal was showing 54, which is 9pt, and 9pt put the anchor on the
    /// window's bottom edge instead of the input box. A 6pt floor let that
    /// through.
    private static func rectangle(
        forRow row: Int, of grid: (first: Int, rows: Int), in pane: NSRect, source: Source
    ) -> Outcome {
        let pitch = pane.height / CGFloat(grid.rows)
        guard (12.0...34.0).contains(pitch), (grid.first..<grid.first + grid.rows).contains(row)
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
        return .found(Found(rect: rect, text: rect, source: source))
    }

    /// The rows the pane is showing: the first one, and how many.
    ///
    /// The rows on *screen*, which is not the same question as how many rows
    /// have text on them. Get that wrong and the pitch is wrong by the ratio
    /// between the two, and the pill goes to a row that is plausible and not
    /// the right one.
    ///
    /// `AXVisibleCharacterRange` is the range on screen, so the lines it spans
    /// are the rows on screen. Asked first because it is the only answer that
    /// is about the viewport at all — and it also gives the row the top of the
    /// pane is showing, which a row index has to be counted from when the value
    /// carries scrollback above it.
    ///
    /// Without that attribute, nothing. Counting the lines the value holds was
    /// tried and does not work: that is how many rows have text on them, which
    /// is the viewport only if the app pads the rows nothing was written to,
    /// and the value gives no reliable way to tell whether it did. Get it wrong
    /// and the pitch is wrong by the ratio between the two — 40 lines of a
    /// 53-row screen is 22.9pt against a real 17.3pt, close enough to pass any
    /// check on the number and still a quarter of the way down the screen.
    ///
    /// So the grid needs the viewport or it gets nothing, and the pill stays
    /// where it opened. The arithmetic itself is sound where the viewport is
    /// known: 53 rows over a 917pt pane is 17.3pt, a real line height rather
    /// than a fit.
    ///
    /// That 53 came from a pane with no history in it, which is the thing to
    /// know about the attribute. Once a Ghostty pane has scrolled, its value
    /// carries the scrollback and `AXVisibleCharacterRange` answers `0` and
    /// the whole length — so it is not imprecise about the viewport, it is
    /// untrue about it, and untrue in exactly the panes that have scrolled.
    /// Measured, the refusal reads "the grid says row 1364 of 1365 at 1pt",
    /// which is the plausibility check below doing its job. It stays refusing:
    /// there is no viewport in that answer to be had.
    private static func visibleGrid(
        of element: AXUIElement, before deadline: Deadline? = nil
    ) -> (first: Int, rows: Int)? {
        guard let visible = range(
                  kAXVisibleCharacterRangeAttribute, of: element, before: deadline),
              visible.length > 0,
              let first = line(of: visible.location, in: element, before: deadline),
              let last = line(
                  of: visible.location + visible.length - 1, in: element, before: deadline),
              last >= first
        else { return nil }
        return (first, last - first + 1)
    }

    /// How many lines of a slice have anything on them.
    ///
    /// Spaces and tabs are nothing: a terminal pads with both, and a row of
    /// them is a blank row however it was drawn.
    private static func contentLines(in units: ArraySlice<UInt16>) -> Int {
        var lines = 0
        var occupied = false
        for unit in units {
            if unit == 0x0A {
                if occupied { lines += 1 }
                occupied = false
            } else if unit != 0x20, unit != 0x09 {
                occupied = true
            }
        }
        return occupied ? lines + 1 : lines
    }

    /// Which row of the grid an index sits on. Nil when the app will not say.
    private static func line(
        of index: Int, in element: AXUIElement, before deadline: Deadline? = nil
    ) -> Int? {
        var out: CFTypeRef?
        guard deadline?.arm(element) != false,
              AXUIElementCopyParameterizedAttributeValue(
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
    private static func range(
        _ attribute: String, of element: AXUIElement, before deadline: Deadline? = nil
    ) -> CFRange? {
        var value: CFTypeRef?
        guard deadline?.arm(element) != false,
              AXUIElementCopyAttributeValue(
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

    private static func frame(of element: AXUIElement, before deadline: Deadline? = nil) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        var position: CFTypeRef?
        var extent: CFTypeRef?
        guard deadline?.arm(element) != false,
              AXUIElementCopyAttributeValue(
                  element, kAXPositionAttribute as CFString, &position) == .success,
              deadline?.arm(element) != false,
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
