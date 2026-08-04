import AppKit
import ApplicationServices

/// The editable thing in front of you, as one string and one span into it.
///
/// Everything that edits text in place used to ask its own question. One path
/// searched the accessibility value for a needle, another reconstructed a
/// terminal's input box and retyped the whole line, a third read
/// `kAXSelectedTextRange` — three coordinate systems, none of which could be
/// handed to the next. So a caller that knew exactly which characters it wanted
/// changed had no way to say so, and expressed it as "find this text" instead,
/// which is a different and much weaker request.
///
/// This is the one answer: `content` is the whole editable text, `span` is the
/// selection as offsets *into that string*, and `replace` substitutes a range of
/// it and nothing else. What a prompt then does with the content and the span is
/// somebody else's problem — this layer only has to be right about where the
/// characters are and whether they moved.
///
/// ## Two kinds, and why there are not more
///
/// The tempting split is by app: a native field, an Electron composer, a
/// browser, a terminal. Three of those four are the same thing — the value is
/// the content and the offsets address it — and they differ only in which write
/// they will accept, which `replace` discovers by writing and reading back. A
/// classification made in advance would be a guess dressed as a fact; the ladder
/// finds out instead.
///
/// The terminal is genuinely different, and not by degree. Its value is a
/// picture of a screen: the input box has to be read back out of it, the
/// offsets in that reconstruction address nothing the app can write, and setting
/// a range there *succeeds* while changing nothing — the lie this whole file
/// exists to survive. So that one is named rather than examined, the same way
/// `Destination` names it, and it gets a write path that touches only keystrokes.
struct Surface {

    enum Kind {
        /// The accessibility value is the content, and its offsets address it.
        /// A native field, a browser input, an Electron composer.
        case editable
        /// The value is a terminal screen. `content` is the input box read out
        /// of it, and no offset into that addresses anything writable.
        case screen
    }

    let kind: Kind
    let element: AXUIElement
    /// The whole editable content, in one coordinate space.
    let content: String
    /// The selection, as offsets into `content`. Nil when nothing is selected;
    /// an empty range is a caret.
    let span: Range<String.Index>?

    var selectedText: String? { span.map { String(content[$0]) } }

    // MARK: - Reading

    /// What is in front, read once.
    ///
    /// Nil rather than an empty surface when there is nothing to edit: a caller
    /// that cannot tell "an empty field" from "no field" writes into neither
    /// safely.
    /// `dictated` is used for one thing only, and only in a terminal that draws
    /// no box: finding *which row* the input is on. It never says what is on
    /// that row. The distinction is load-bearing — a field can hold several
    /// dictations and whatever was typed between them, so treating the last
    /// transcript as the content would quietly delete the rest.
    ///
    /// Retried briefly, for the same reason every write in this file is polled:
    /// activating a window is a request, and the accessibility tree settles a
    /// beat after it. Ghostty in particular reports the *window* as the focused
    /// element for a few hundred milliseconds after coming forward, and hands
    /// back its text view only once focus has landed — read once and
    /// immediately, that is indistinguishable from a terminal that publishes
    /// nothing at all, and it was misread exactly that way. Two cases in the
    /// Ghostty run failed on it and neither corrupted anything; they simply read
    /// an empty screen and declined.
    static func read(
        element: AXUIElement? = nil,
        app: NSRunningApplication? = nil,
        dictated: String? = nil
    ) -> Surface? {
        let deadline = Date().addingTimeInterval(0.6)
        var attempt = 0
        while true {
            if let surface = readOnce(element: element, app: app, dictated: dictated) {
                if attempt > 0 {
                    Log.write("surface: readable on attempt \(attempt + 1)")
                }
                return surface
            }
            attempt += 1
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.08)
        }
    }

    private static func readOnce(
        element: AXUIElement? = nil,
        app: NSRunningApplication? = nil,
        dictated: String? = nil
    ) -> Surface? {
        guard Permissions.accessibility == .granted else {
            Log.write("surface: accessibility is not granted")
            return nil
        }
        guard let element = element ?? SelectionReader.focusedElement() else {
            Log.write("surface: nothing focused")
            return nil
        }
        guard !SelectionReader.isOurs(element) else {
            Log.write("surface: the focused element is our own")
            return nil
        }
        guard let value = SelectionReader.visibleText(of: element) else {
            // Ghostty and iTerm land here and always will: they focus the
            // window, render their screen with Metal, and publish nothing but
            // chrome to accessibility. Walking down from the window finds their
            // tab title — 44 characters where the screen is two thousand — and
            // treating that as the input line would retype chrome into the pty.
            // So this refuses, and the text goes to the clipboard.
            Log.write("surface: the focused element has no readable value")
            return nil
        }

        let front = app ?? NSWorkspace.shared.frontmostApplication
        let isTerminal = front.map {
            Destination.terminalName(of: Pipeline.App(
                name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? ""
            )) != nil
        } ?? false

        if isTerminal {
            return screen(element: element, value: value, dictated: dictated)
        }
        return editable(element: element, value: value)
    }

    /// A field, a browser input, a composer: the value is the content.
    private static func editable(element: AXUIElement, value: String) -> Surface {
        var span: Range<String.Index>?
        if let range = SelectionReader.selectedRange(of: element),
           range.location != NSNotFound, range.location >= 0 {
            let nsRange = NSRange(location: range.location, length: max(0, range.length))
            span = Range(nsRange, in: value)
            if span == nil {
                Log.write("surface: selected range \(range.location)+\(range.length)"
                    + " does not fit \(value.count) chars of value; ignoring it")
            }
        }
        return Surface(kind: .editable, element: element, content: value, span: span)
    }

    /// A terminal: the content is the input box, dug back out of the screen.
    ///
    /// The box is found by the rules the TUI draws around it, never by
    /// recognising text we believe we put there. That distinction is the whole
    /// reason several sentences dictated into one box survive being edited: the
    /// box is authoritative about its contents and it is authoritative about
    /// *all* of them, where a transcript only ever describes the last one and
    /// retyping from it would delete the rest.
    private static func screen(
        element: AXUIElement, value: String, dictated: String?
    ) -> Surface? {
        // The box first, and a single row only when no box is drawn — a bare
        // shell rather than a TUI. That fallback is the one place a transcript
        // is consulted, and it still reads the whole row it lands on.
        guard let box = SelectionReader.joinedInputBox(in: value)
            ?? SelectionReader.inputLine(anchoredBy: dictated, in: value) else {
            Log.write("surface: terminal, but nothing identifies the input line")
            return nil
        }
        // An empty box is nothing to substitute into, so nil is the honest
        // answer either way — and it lets the retry above tell a screen that has
        // not finished being drawn from one that is genuinely empty.
        guard !box.isEmpty else { return nil }
        guard box.count <= maxScreenContent else {
            Log.write("surface: the input box holds \(box.count) chars; too much to retype")
            return nil
        }

        // A terminal's selection is of its *output* — the whole screen is
        // selectable and none of it is the input. So a selection only means
        // something here when it lands unambiguously inside the box, and
        // "unambiguously" has to mean exactly one occurrence: a word that
        // appears twice gives no way to tell which one was highlighted, and
        // guessing puts the edit on the wrong half of the line.
        var span: Range<String.Index>?
        if let selected = SelectionReader.selectedText(of: element),
           !selected.isEmpty {
            let matches = occurrences(of: selected, in: box)
            if matches.count == 1 {
                span = matches[0]
            } else {
                Log.write("surface: \"\(selected.prefix(40))\" appears \(matches.count)"
                    + " times in the input box; cannot say which was selected")
            }
        }
        return Surface(kind: .screen, element: element, content: box, span: span)
    }

    /// Retyping a whole line is proportional to its length, and past a point the
    /// clipboard is the kinder answer.
    private static let maxScreenContent = 2000

    private static func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = haystack.startIndex
        while let next = haystack.range(of: needle, range: from..<haystack.endIndex) {
            found.append(next)
            from = next.upperBound
            if found.count > 1 { break }
        }
        return found
    }

    // MARK: - Locating

    /// The smallest range of `before` whose replacement turns it into `after`.
    ///
    /// Common prefix, common suffix, and whatever is left in the middle. Exact
    /// rather than clever: no tokenising, no similarity, nothing that can
    /// disagree with itself on a second run.
    ///
    /// This is what lets a whole-text rewrite become an in-place substitution.
    /// A prompt handed a sentence returns a sentence, and pasting that over the
    /// field is what loses the caret and everything typed since; the difference
    /// between the two is usually one word, and this finds it.
    ///
    /// Nil when the strings are equal, which is a caller asking to change
    /// nothing and is worth being told about rather than performing.
    static func minimalSpan(
        from before: String, to after: String
    ) -> (range: Range<String.Index>, replacement: String)? {
        guard before != after else { return nil }

        var start = before.startIndex
        var afterStart = after.startIndex
        while start < before.endIndex, afterStart < after.endIndex,
              before[start] == after[afterStart] {
            start = before.index(after: start)
            afterStart = after.index(after: afterStart)
        }

        var end = before.endIndex
        var afterEnd = after.endIndex
        while end > start, afterEnd > afterStart,
              before[before.index(before: end)] == after[after.index(before: afterEnd)] {
            end = before.index(before: end)
            afterEnd = after.index(before: afterEnd)
        }

        return (start..<end, String(after[afterStart..<afterEnd]))
    }

    /// The range holding `needle`, nearest the end.
    ///
    /// Last rather than first: the word being corrected was dictated a moment
    /// ago, so the most recent occurrence is the one meant.
    func range(of needle: String) -> Range<String.Index>? {
        content.range(of: needle, options: [.caseInsensitive, .backwards])
    }

    // MARK: - Writing

    enum Outcome: Equatable {
        /// The characters in that range, and no others, now read differently.
        case replaced
        /// Nothing was written, and nothing was disturbed trying.
        case refused(String)
    }

    /// Substitutes one range of `content`, and nothing else.
    ///
    /// Every branch below either changes exactly those characters or changes
    /// nothing at all. There is no branch that writes and hopes: the two failures
    /// are not the same size, and the one that appends a correction to the end of
    /// somebody's sentence is the one this file exists to prevent.
    @discardableResult
    func replace(
        _ range: Range<String.Index>, with replacement: String
    ) -> Outcome {
        let updated = content.replacingCharacters(in: range, with: replacement)
        guard updated != content else {
            return .refused("the text already reads that way")
        }

        switch kind {
        case .editable:
            return writeEditable(range, replacement: replacement, updated: updated)
        case .screen:
            return writeScreen(updated: updated)
        }
    }

    // MARK: - The editable ladder

    /// Three attempts, each verified by reading back, then a refusal.
    ///
    /// The order is by how little each disturbs. Nothing here trusts a return
    /// value: setting an accessibility attribute reports `.success` in surfaces
    /// that then ignore it entirely, which is the single fact that has caused
    /// every corrupted line this code has ever produced.
    private func writeEditable(
        _ range: Range<String.Index>, replacement: String, updated: String
    ) -> Outcome {
        let nsRange = NSRange(range, in: content)
        // The replacement in the company it is meant to keep. Checking for the
        // replacement alone would accept an append — "…the storethey're"
        // contains "they're" quite happily — so the surrounding characters are
        // what make this a check rather than a formality.
        let fragment = self.fragment(around: range, replacement: replacement)

        // 1. Set the range, then write the text into it. Disturbs nothing, and
        //    is what a native field accepts.
        if select(nsRange), setSelectedText(replacement), landed(fragment) {
            Log.write("surface: wrote \(nsRange.length) chars via the accessibility range")
            return .replaced
        }

        // 2. Set the range and paste over it. Chromium and Electron implement
        //    selecting but not writing, so this is the branch that carries the
        //    web — and the read-back is what makes it safe. Skipping the
        //    question is what turns a paste into an append.
        if select(nsRange),
           confirmedSelection(matches: String(content[range]), range: nsRange) {
            Log.write("surface: the range write was ignored; pasting over a confirmed selection")
            TextInserter.insert(replacement, mode: .paste)
            if settled(on: fragment) {
                return .replaced
            }
            return .refused(repairedAfterStrayPaste())
        }

        // 3. Walk the caret to the span with arrow keys and select it by hand.
        //
        //    Measured, not guessed: Chromium accepts `AXSelectedTextRange` on a
        //    contenteditable, returns `.success`, and leaves the selection
        //    exactly where it was — asked for 14+10 it went on reporting 43+0.
        //    That rules out both branches above for every browser and every
        //    Electron app, which is most of the places anyone writes prose.
        //
        //    What the same measurement gives back is the way through. Chromium
        //    will not *move* the selection on request, but it reports where the
        //    caret is perfectly honestly — so the caret can be walked from where
        //    it is to where the span starts, and every step of that walk can be
        //    checked against the app's own account before anything is typed.
        if let outcome = writeByWalkingTheCaret(
            nsRange, replacement: replacement, fragment: fragment
        ) {
            return outcome
        }

        return .refused("this app would not let me edit it")
    }

    /// Selects a range the way a person would, and pastes over it.
    ///
    /// The branch that carries the web. Everything before it asks the app to
    /// move the selection; this one moves it with the same keystrokes a person
    /// would use, which is the one instruction a text surface cannot decline
    /// without ceasing to be one.
    ///
    /// It is not blind, which is what separates it from the retype that used to
    /// live here. Arrow keys change no text, so every step up to the paste is
    /// free to fail — and each one is checked against the range the app reports
    /// before the next is taken. By the time anything is written, the app has
    /// said in its own words that exactly the intended characters are selected.
    ///
    /// Nil rather than a refusal when the walk is too long to be worth taking,
    /// so the caller can fall through to its own last resort.
    private func writeByWalkingTheCaret(
        _ target: NSRange, replacement: String, fragment: String
    ) -> Outcome? {
        guard var caret = caretOffset() else {
            Log.write("surface: the app will not say where the caret is; cannot walk to the span")
            return nil
        }

        let end = target.location + target.length
        let distance = abs(end - caret) + target.length
        guard distance <= Surface.maxCaretTravel else {
            Log.write("surface: the span is \(distance) keystrokes away; too far to walk")
            return nil
        }

        // Collapse an existing selection first, so the caret is somewhere
        // arithmetic can be done about. Right rather than left, which puts it at
        // the end of what was selected — the same place a person's caret ends up.
        if let current = SelectionReader.selectedRange(of: element), current.length > 0 {
            post(arrowRight)
            guard let collapsed = caretOffset() else { return nil }
            caret = collapsed
        }

        let step = end > caret ? arrowRight : arrowLeft
        post(step, times: abs(end - caret))
        guard let landed = caretOffset(), landed == end else {
            Log.write("surface: walked to \(end) but the caret reports"
                + " \(caretOffset().map(String.init) ?? "nothing") — not typing")
            return nil
        }

        post(arrowLeft, times: target.length, flags: .maskShift)
        let got = SelectionReader.selectedRange(of: element)
        guard let selected = got,
              selected.location == target.location, selected.length == target.length else {
            let reported = got.map { "\($0.location)+\($0.length)" } ?? "nothing"
            Log.write("surface: selected \(reported), wanted"
                + " \(target.location)+\(target.length) — not typing")
            return nil
        }

        Log.write("surface: walked the caret to \(target.location)+\(target.length); pasting")
        TextInserter.insert(replacement, mode: .paste)
        if settled(on: fragment) { return .replaced }
        return .refused(repairedAfterStrayPaste())
    }

    /// Where the caret is, or nil when the app will not say. A selection counts
    /// as a caret at its start for this purpose; the caller collapses it first.
    private func caretOffset() -> Int? {
        guard let range = SelectionReader.selectedRange(of: element),
              range.location != NSNotFound, range.location >= 0 else { return nil }
        return range.location
    }

    /// Past this it is cheaper and safer to hand over the clipboard. Each step
    /// is one synthesised key event, and a walk long enough to be slow is also
    /// long enough for something else to move the caret underneath it — which
    /// the check afterwards would catch, but only after a visible crawl.
    private static let maxCaretTravel = 400

    private let arrowLeft: CGKeyCode = 123
    private let arrowRight: CGKeyCode = 124

    private func post(_ key: CGKeyCode, times: Int = 1, flags: CGEventFlags = []) {
        guard times > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<times {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { return }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        // One wait for the batch rather than one per key: the app services these
        // in order, and the only moment the result matters is after the last.
        Thread.sleep(forTimeInterval: 0.05 + Double(times) * 0.004)
    }

    /// Undoes a paste that went somewhere other than where it was aimed.
    ///
    /// Cmd-Z rather than another accessibility write, because the surface has
    /// just demonstrated that it does not honour those, and a repair built on
    /// the mechanism that failed is not a repair. A paste is an ordinary edit in
    /// every app this branch reaches — a browser, a composer, a mail body — and
    /// undoing an ordinary edit is what their own history is for.
    ///
    /// Only when something actually changed. If the value still reads exactly as
    /// it did, the paste landed nowhere and there is nothing of ours to take
    /// back — pressing Cmd-Z then would undo whatever the person did before we
    /// arrived, which is a far worse outcome than the failed correction.
    private func repairedAfterStrayPaste() -> String {
        guard let now = SelectionReader.visibleText(of: element),
              folded(now) != folded(content) else {
            Log.write("surface: the paste changed nothing; leaving the field alone")
            return "this app would not let me edit it"
        }

        Log.write("surface: the paste landed somewhere unintended; undoing it")
        SelectionReader.postCommandKey(0x06)   // Cmd-Z

        let deadline = Date().addingTimeInterval(1.0)
        repeat {
            if let value = SelectionReader.visibleText(of: element),
               folded(value) == folded(content) {
                Log.write("surface: the stray paste is undone; the text is as it was")
                return "this app would not let me edit it"
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline

        // Said as loudly as a log line can. Everything else in this file exists
        // to make this branch unreachable.
        Log.write("surface: ⚠︎ the stray paste would not undo — the field may hold the wrong text")
        return "the edit went wrong and would not undo — check the text"
    }

    /// True once the value reads the way it would if the substitution had
    /// happened — polled, because a paste is a request and the app services it
    /// when it is ready.
    ///
    /// Reading once after a guessed delay measures the delay, not the write, and
    /// concluding failure from that is worse than not checking at all: the
    /// recovery then destroys work that was fine.
    private func settled(on fragment: String) -> Bool {
        let deadline = Date().addingTimeInterval(1.0)
        repeat {
            if landed(fragment) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    /// The replacement with up to 12 characters of its surroundings on each
    /// side — the shape the value must take for the edit to have happened in
    /// the place it was asked to happen. An append does not produce it.
    private func fragment(around range: Range<String.Index>, replacement: String) -> String {
        let context = 12
        return String(content[..<range.lowerBound].suffix(context))
            + replacement
            + String(content[range.upperBound...].prefix(context))
    }

    private func landed(_ fragment: String) -> Bool {
        guard let value = SelectionReader.visibleText(of: element) else { return false }
        return folded(value).contains(folded(fragment))
    }

    /// Typographic substitution is not a failed write. Most apps turn a straight
    /// apostrophe curly as it arrives, so "they're" comes back as "they’re" — the
    /// edit landed, and a literal comparison would call it a refusal.
    private func folded(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    private func select(_ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value
        ) == .success
    }

    private func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    /// Whether the app agrees that what is selected is what we aimed at.
    ///
    /// Its own function because it is the only thing standing between a paste
    /// and somebody's document. Confirming our own action is not evidence — we
    /// set the range a moment ago, so asking "is there a selection" answers yes
    /// whatever happened. The question has to be one the app answers out of its
    /// own state.
    ///
    /// Two ways it can answer, because the surfaces that matter answer
    /// differently. A native field hands back the selected *text*, which is the
    /// stronger evidence and is tried first. Chromium hands back `""` for the
    /// selected text of a contenteditable however the selection was made — by
    /// hand, by us, at all — so insisting on text refuses every browser and
    /// every Electron app on earth. What it does report honestly is the
    /// *range*, and a range that reads back as the one we asked for, when the
    /// one before it was different, is the app saying it moved the selection.
    ///
    /// Neither answer is taken as proof that the write worked. They only decide
    /// whether pasting is safe to attempt; what happened afterwards is settled
    /// by reading the value back, and by the repair below when it went wrong.
    /// Polled, and that is not a detail. Setting a selection is a request, and
    /// Chromium services it a beat later — read once and immediately, it reports
    /// the caret exactly where it was, which reads identically to "this app
    /// ignores range writes". That misreading is what sent the first version of
    /// this file off building a keystroke walk for a branch that already worked.
    /// The same mistake, in the same shape, is recorded twice more in this file
    /// about pastes: reading before the app has serviced the request measures
    /// the delay, not the write.
    private func confirmedSelection(matches expected: String, range: NSRange) -> Bool {
        var lastSeen = "nothing"
        let deadline = Date().addingTimeInterval(0.6)
        repeat {
            if let selected = SelectionReader.selectedText(of: element), !selected.isEmpty {
                if folded(selected).compare(
                    folded(expected), options: .caseInsensitive
                ) == .orderedSame {
                    return true
                }
                lastSeen = "\"\(selected.prefix(40))\""
            } else if let echoed = SelectionReader.selectedRange(of: element) {
                // Chromium reports `""` for the selected text of a
                // contenteditable however the selection was made — by hand, by
                // us, at all — so insisting on text refuses every browser and
                // every Electron app. The range it does report honestly.
                if echoed.location == range.location, echoed.length == range.length {
                    return true
                }
                lastSeen = "\(echoed.location)+\(echoed.length)"
            }
            Thread.sleep(forTimeInterval: 0.03)
        } while Date() < deadline

        Log.write("surface: asked to select \(range.location)+\(range.length),"
            + " the app still reports \(lastSeen); not pasting")
        return false
    }

    // MARK: - The screen path

    /// A terminal takes keystrokes and refuses everything else, so the input
    /// line is cleared and retyped whole — computed from the span, but written
    /// as one line because that is the only unit a terminal exposes.
    ///
    /// The caret's position inside the input is invisible to accessibility, so
    /// there is no way to address a range here without assuming where it starts,
    /// and an assumption that is wrong edits the wrong characters.
    private func writeScreen(updated: String) -> Outcome {
        guard let config = try? ConfigStore.load(), config.transcription.rewriteLine else {
            return .refused("rewrite_line is off, so terminals cannot be edited")
        }
        guard clearedBox() else {
            return .refused("could not empty the line; not retyping over what is left")
        }

        TextInserter.insert(updated, mode: .paste)
        if box(reads: updated) {
            Log.write("surface: retyped \(updated.count) chars of input line")
            return .replaced
        }

        // Put it back deliberately rather than with Ctrl-Y. The paste has
        // already happened, so yanking inserts what Ctrl-K took *after*
        // whatever landed and leaves you holding both — which is how a truncated
        // correction became a duplicated line. We still have the text that was
        // there, so type that and depend on nothing.
        Log.write("surface: the line did not come back as expected; restoring it")
        _ = clearedBox()
        TextInserter.insert(content, mode: .paste)
        Thread.sleep(forTimeInterval: 0.20)
        return .refused("the terminal would not take the rewrite")
    }

    /// Empties the input line, checking between presses rather than assuming.
    ///
    /// Ctrl-K kills to the end of the *visual row* in this TUI, not the end of
    /// the logical line, so one press leaves behind everything a wrap pushed
    /// onto the rows below — and the retype then lands on top of the remainder.
    /// Pressing until the box reads empty is the only version of this that
    /// survives a line that wrapped.
    ///
    /// There is no blind branch. There used to be: when the box could not be
    /// read this pressed the keys anyway and returned `true`, which on any
    /// surface that does not implement readline meant nothing was cleared and
    /// the caller pasted onto the end of the line. That is the append.
    private func clearedBox() -> Bool {
        for _ in 0..<12 {
            switch boxIsEmpty() {
            case true: return true
            case false: break
            case nil:
                Log.write("surface: cannot read the input box back; refusing to clear blind")
                return false
            }
            SelectionReader.postControlKey(0x00)   // Ctrl-A, start of line
            Thread.sleep(forTimeInterval: 0.06)
            SelectionReader.postControlKey(0x28)   // Ctrl-K, kill to end of line
            Thread.sleep(forTimeInterval: 0.12)
        }
        return boxIsEmpty() == true
    }

    private func boxIsEmpty() -> Bool? {
        guard let value = SelectionReader.visibleText(of: element),
              let box = SelectionReader.joinedInputBox(in: value) else { return nil }
        return box.isEmpty
    }

    /// Whether the box now holds exactly the text we retyped.
    ///
    /// Equality, not containment. A box reading "Jery is on vacationJerry is on
    /// vacation" *contains* the corrected line, and containment is what reported
    /// that append as a clean retype for as long as this bug existed.
    private func box(reads expected: String) -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            if let value = SelectionReader.visibleText(of: element),
               let box = SelectionReader.joinedInputBox(in: value),
               folded(box) == folded(expected) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }
}
