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
    /// The app the element belongs to, so an undo can go back to it rather than
    /// to whatever happens to be in front when it is asked for.
    let owner: NSRunningApplication?
    /// The whole editable content, in one coordinate space.
    let content: String
    /// The selection, as offsets into `content`. Nil when nothing is selected;
    /// an empty range is a caret.
    let span: Range<String.Index>?

    var selectedText: String? { span.map { String(content[$0]) } }

    /// The pasteboard flavours this app takes, over and above plain text.
    ///
    /// A rewrite is written the same way a dictation is, because it is the same
    /// text going into the same field. Without this it went in plain, so a
    /// transform that answered `**Alex**` put four asterisks into Slack where a
    /// dictation of the same words arrives bold. Nothing said so: a paste that
    /// lands is a paste that worked, and the markers look like the model's
    /// fault rather than the paste's.
    ///
    /// A terminal answers `.plain` here, which is what `writeScreen` needs and
    /// gets by not asking.
    var paste: AppProfile.Paste { AppProfile.of(owner).paste }

    /// What the field will show once `replacement` has been pasted.
    ///
    /// Not the same string when the app takes a rich flavour: `**Alex**` goes
    /// onto the pasteboard as markup and arrives as bold Alex, with the markers
    /// gone. Every write here is verified by reading the field back, so the
    /// check has to look for what will be *there* rather than for what was
    /// sent. Measured the moment the flavour was carried into a rewrite: a
    /// bold that applied correctly reported "this app won't let me edit it",
    /// because the read-back went looking for two asterisks Slack had consumed.
    ///
    /// Only the paste renders. `setSelectedText` writes the string literally,
    /// so that branch still reads back the markers it put there.
    ///
    /// `displayed` and not `plain`. They differ on one thing — a labelled link,
    /// which `plain` writes as `words (url)` because that flavour is the
    /// clipboard fallback and losing the address there is worse than showing
    /// it. On screen the address is in the anchor and the line reads "words",
    /// so a read-back against `plain` would reject a link that pasted
    /// correctly and the repair would undo it.
    func asShown(_ replacement: String) -> String {
        guard paste != .plain else { return replacement }
        let markup = Markup.parse(replacement)
        return markup.isPlain ? replacement : markup.displayed
    }

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
            // A window that has not finished handing over its text view lands
            // here too, which is why `read` retries rather than taking this as
            // final. Ghostty and iTerm both answer this way for a few hundred
            // milliseconds after coming forward, and reading them once was
            // enough to write them up as terminals that publish nothing at all.
            //
            // Walking down from the window to find *some* text was tried and
            // taken out again: it reaches the tab title long before the screen,
            // and retyping that into a pty is worse than declining. Waiting is
            // the fix; searching is not.
            Log.write("surface: the focused element has no readable value")
            return nil
        }

        let front = app ?? NSWorkspace.shared.frontmostApplication
        let isTerminal = AppProfile.of(front).focus == .screen

        if isTerminal {
            return screen(element: element, owner: front, value: value, dictated: dictated)
        }
        return editable(element: element, owner: front, value: value)
    }

    /// A field, a browser input, a composer: the value is the content.
    private static func editable(
        element: AXUIElement, owner: NSRunningApplication?, value: String
    ) -> Surface {
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
        return Surface(kind: .editable, element: element, owner: owner, content: value, span: span)
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
        element: AXUIElement, owner: NSRunningApplication?, value: String, dictated: String?
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
        return Surface(kind: .screen, element: element, owner: owner, content: box, span: span)
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

    /// `minimalSpan`, grown until it is a span a paste can carry.
    ///
    /// The minimal answer is often not writable. Three real dictations, all in
    /// Slack, all on 2026-08-20:
    ///
    ///   "one you" → "one do you"      nothing, at one point, becomes "do "
    ///   "car though" → "car, though"  nothing, at one point, becomes ","
    ///   "I'll t I told" → "I told"    "'ll t I" becomes nothing
    ///
    /// Each one fails, and for its own reason. `TextInserter.insert("")` does
    /// nothing at all, so the third never writes and the ladder cannot tell
    /// that from a write the app refused. Slack drops a trailing space off a
    /// paste, so the first lands as "one doyou". And the first two both ask to
    /// paste at a caret rather than over a selection, which is the one thing
    /// step 2 of the ladder cannot check: `confirmedSelection` over an empty
    /// range confirms that nothing is selected, which is true wherever the
    /// caret happens to be.
    ///
    /// So the span grows until three things hold. It covers at least one real
    /// character, so the app has to say in its own words which characters are
    /// selected before anything is written. The replacement is not empty, so
    /// there is something to paste. And neither end of the replacement is
    /// whitespace, so an editor entitled to tidy the whitespace it is handed
    /// has nothing of ours to tidy.
    ///
    /// It grows outward over text the two strings agree on, so the result is
    /// the same edit written differently: "insert `do ` before `you`" becomes
    /// "replace `y` with `do y`". One character at a time, and it stops as soon
    /// as the three hold — a bigger span is more to paste and more to put back
    /// if the paste goes wrong.
    static func writableSpan(
        from before: String, to after: String
    ) -> (range: Range<String.Index>, replacement: String)? {
        guard let (span, minimal) = minimalSpan(from: before, to: after) else { return nil }

        var start = span.lowerBound
        var end = span.upperBound
        var replacement = minimal

        // The characters outside the span are the ones both strings share, so
        // taking one from `before` is taking the same one from `after`.
        func growForwards() {
            replacement.append(before[end])
            end = before.index(after: end)
        }
        func growBackwards() {
            start = before.index(before: start)
            replacement.insert(before[start], at: replacement.startIndex)
        }

        while true {
            // Which side is wrong decides which way to grow, and a leading
            // space is only ever fixed by growing backwards. Growing the other
            // way instead is how this ate a whole line the first time it ran.
            //
            // Whitespace against the edge of the line is not a hazard: there is
            // nothing out there for an editor to join it to.
            let leading = replacement.first?.isWhitespace == true && start > before.startIndex
            let trailing = replacement.last?.isWhitespace == true && end < before.endIndex

            if leading {
                growBackwards()
            } else if trailing || replacement.isEmpty || start == end {
                if end < before.endIndex {
                    growForwards()
                } else if start > before.startIndex {
                    growBackwards()
                } else {
                    // A line with nothing left to grow into. A caller that
                    // writes this is no worse off than it was.
                    break
                }
            } else {
                break
            }
        }

        return (start..<end, replacement)
    }

    /// The range holding `needle`, nearest the end.
    ///
    /// Last rather than first: the word being corrected was dictated a moment
    /// ago, so the most recent occurrence is the one meant.
    func range(of needle: String) -> Range<String.Index>? {
        content.range(of: needle, options: [.caseInsensitive, .backwards])
    }

    /// Every range holding `needle`, in the order they appear.
    ///
    /// For callers that have to know whether the text is ambiguous before they
    /// pick one. "Nearest the end" is a fine answer when the word was dictated a
    /// moment ago and a bad one when the caller is pointing at a specific
    /// occurrence — and the difference between those is not visible from a
    /// single range.
    func ranges(of needle: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = content.startIndex
        while let next = content.range(
            of: needle, options: [.caseInsensitive], range: from..<content.endIndex
        ) {
            found.append(next)
            from = next.lowerBound < next.upperBound
                ? next.upperBound
                : content.index(after: next.lowerBound)
            if from >= content.endIndex { break }
        }
        return found
    }

    // MARK: - Writing

    enum Outcome: Equatable {
        /// The characters in that range, and no others, now read differently.
        case replaced(Undo)
        /// Nothing was written, and nothing was disturbed trying.
        case refused(String)
    }

    /// What it takes to put a substitution back.
    ///
    /// The whole content on both sides rather than a range and a string: by the
    /// time an undo is asked for, the surface has been written to, and any range
    /// recorded beforehand describes a string that no longer exists. Two
    /// snapshots can always be checked against what is actually there, which is
    /// the one question undo has to get right — *is this still the text I
    /// wrote?* — and a range cannot answer it at all.
    struct Undo: Equatable {
        let before: String
        let after: String
        /// What the substitution was called, for the toast and the log.
        let describedAs: String
        /// The element that was written to, and the app it belongs to.
        ///
        /// Without these an undo goes wherever the caret happens to be, and the
        /// content check is not enough to catch it: two fields holding the same
        /// sentence are not unusual — a message and the reply quoting it, the
        /// same text pasted into a second window — and one of them would be
        /// rewritten while the substitution it was meant to reverse stayed put.
        /// The text says whether it is safe to undo; only the element says
        /// where.
        let element: AXUIElement
        let owner: NSRunningApplication?

        static func == (lhs: Undo, rhs: Undo) -> Bool {
            lhs.before == rhs.before && lhs.after == rhs.after
        }
    }

    /// Substitutes one range of `content`, and nothing else.
    ///
    /// Every branch below either changes exactly those characters or changes
    /// nothing at all. There is no branch that writes and hopes: the two failures
    /// are not the same size, and the one that appends a correction to the end of
    /// somebody's sentence is the one this file exists to prevent.
    @discardableResult
    func replace(
        _ range: Range<String.Index>, with replacement: String, describedAs label: String = "edit"
    ) -> Outcome {
        let updated = content.replacingCharacters(in: range, with: replacement)
        guard updated != content else {
            return .refused("the text already reads that way")
        }
        let undo = Undo(
            before: content, after: updated, describedAs: label,
            element: element, owner: owner
        )

        switch kind {
        case .editable:
            return writeEditable(range, replacement: replacement, updated: updated, undo: undo)
        case .screen:
            return writeScreen(updated: updated, undo: undo)
        }
    }

    /// Puts the content back the way it was before a substitution.
    ///
    /// Refuses when the text has moved on. An undo that fires against edited
    /// text is not an undo, it is a second unwanted edit — and it would land
    /// exactly where the user had just started fixing things by hand.
    static func undo(_ record: Undo) -> Outcome {
        // The recorded element, never `focusedElement()`. Reading whatever is
        // focused is how an undo lands in the wrong window — and the content
        // check below cannot catch that, because it is a question about the text
        // rather than about which field holds it.
        guard let surface = read(element: record.element, app: record.owner) else {
            return .refused("the field it changed is not there any more")
        }
        guard surface.folded(surface.content) == surface.folded(record.after) else {
            return .refused("the text has changed since; leaving it alone")
        }
        guard let edit = writableSpan(from: record.after, to: record.before) else {
            return .refused("there is nothing to put back")
        }
        // Located against `record.after`, which we have just confirmed is what
        // is on screen, so the offsets are the surface's own.
        guard let range = Range(
            NSRange(edit.range, in: record.after), in: surface.content
        ) else {
            return .refused("could not place the undo in the field")
        }
        return surface.replace(range, with: edit.replacement, describedAs: "undo")
    }

    // MARK: - The editable ladder

    /// Three attempts, each verified by reading back, then a refusal.
    ///
    /// The order is by how little each disturbs. Nothing here trusts a return
    /// value: setting an accessibility attribute reports `.success` in surfaces
    /// that then ignore it entirely, which is the single fact that has caused
    /// every corrupted line this code has ever produced.
    private func writeEditable(
        _ range: Range<String.Index>, replacement: String, updated: String, undo: Undo
    ) -> Outcome {
        let nsRange = NSRange(range, in: content)
        // The replacement in the company it is meant to keep. Checking for the
        // replacement alone would accept an append — "…the storethey're"
        // contains "they're" quite happily — so the surrounding characters are
        // what make this a check rather than a formality. `updated` is what the
        // value should read afterwards, and the fragment is widened against it
        // until it names one place there.
        let fragment = self.fragment(around: range, replacement: replacement, in: updated)
        // The same check for the branches that paste, against what a paste
        // actually leaves in the field. Identical to `fragment` whenever the
        // app takes plain text or the replacement carries no markup, which is
        // most of the time — see `asShown`.
        let shown = asShown(replacement)
        let pasted = shown == replacement ? fragment : self.fragment(
            around: range, replacement: shown,
            in: content.replacingCharacters(in: range, with: shown)
        )

        // 1. Set the range, then write the text into it. Disturbs nothing, and
        //    is what a native field accepts.
        if select(nsRange), setSelectedText(replacement), landed(fragment, needle: folded(fragment.text)) {
            Log.write("surface: wrote \(nsRange.length) chars via the accessibility range")
            return .replaced(undo)
        }

        // 2. Set the range and paste over it. Chromium and Electron implement
        //    selecting but not writing, so this is the branch that carries the
        //    web — and the read-back is what makes it safe. Skipping the
        //    question is what turns a paste into an append.
        if select(nsRange),
           confirmedSelection(matches: String(content[range]), range: nsRange) {
            Log.write("surface: the range write was ignored; pasting over a confirmed selection")
            TextInserter.insert(replacement, mode: .paste, paste: paste)
            if settled(on: pasted) {
                // Said out loud, like the branch above. Without it a success
                // here is an absence of failure lines, and reading the log for
                // "did the edit land" means knowing which lines are missing.
                Log.write("surface: pasted \(nsRange.length) chars over the selection")
                return .replaced(undo)
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
            nsRange, replacement: replacement, fragment: pasted, undo: undo
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
        _ target: NSRange, replacement: String, fragment: Fragment, undo: Undo
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
        // The characters, not the numbers naming them — the same standard step 2
        // holds itself to, and for a reason step 2 measured. An app's offsets and
        // its own value do not always address the same string: Slack reported
        // exactly 62+25 for a selection holding the characters at 63, so a check
        // on the numbers passed while the selection was one character out, and
        // this pasted over the wrong 25 characters. `confirmedSelection` asks
        // what is selected first and falls back to the numbers only where the app
        // will not say, which is every Chromium contenteditable.
        guard let text = Range(target, in: content).map({ String(content[$0]) }),
              confirmedSelection(matches: text, range: target) else {
            return nil
        }

        Log.write("surface: walked the caret to \(target.location)+\(target.length); pasting")
        TextInserter.insert(replacement, mode: .paste, paste: paste)
        if settled(on: fragment) { return .replaced(undo) }
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
        let foldedContent = folded(content)
        guard let now = SelectionReader.visibleText(of: element),
              folded(now) != foldedContent else {
            Log.write("surface: the paste changed nothing; leaving the field alone")
            return "this app would not let me edit it"
        }

        Log.write("surface: the paste landed somewhere unintended; undoing it")
        SelectionReader.postCommandKey(0x06)   // Cmd-Z

        let deadline = Date().addingTimeInterval(1.0)
        repeat {
            if let value = SelectionReader.visibleText(of: element),
               folded(value) == foldedContent {
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
    private func settled(on fragment: Fragment) -> Bool {
        // Two and a half seconds, not one.
        //
        // Measured in Outlook: the paste landed and was on screen, and this
        // said it had not within the second — so the repair undid an edit that
        // had worked, and the message said the app would not allow one. The
        // read is the slow part. Outlook's message body reported 395,489
        // characters, and every poll copies all of them out of another process
        // that is busy laying the paste out, so a single read can eat most of
        // the old budget and only two or three ever happened.
        let deadline = Date().addingTimeInterval(2.5)
        let needle = folded(fragment.text)
        repeat {
            if landed(fragment, needle: needle) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline

        // Which of the three failures this was. They look identical from the
        // outside and want opposite fixes: text that never arrived is a write
        // that did not happen, text that arrived without its surroundings is
        // this check being too literal, and neither is a paste that went to the
        // wrong place.
        if let value = SelectionReader.visibleText(of: element) {
            let replacement = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write(folded(value).contains(folded(replacement))
                ? "surface: the text is there but not in the context expected;"
                    + " the read-back is stricter than the edit"
                : "surface: the text has not appeared in the field")
        } else {
            Log.write("surface: cannot read the field back to check the edit")
        }
        return false
    }

    /// The replacement with its surroundings — the shape the value must take for
    /// the edit to have happened in the place it was asked to happen. An append
    /// does not produce it.
    ///
    /// Twelve characters after the replacement, and at least twelve before it.
    /// The leading context is widened until it stands in exactly one place in
    /// the text the edit should produce.
    ///
    /// Why widen. `landed` asks whether the value *contains* this, and a
    /// contains cannot tell one place from another. Twelve characters repeat —
    /// a list, a table, the same line quoted further down — and a paste that
    /// misses and lands on the twin then satisfies the check while the place we
    /// aimed at is untouched. That is the failure this file exists to prevent.
    /// A leading context standing in one place pins the position, so the
    /// contains is a question about position again.
    ///
    /// Ordinary prose is already unique after twelve characters, so this
    /// usually returns on the first pass and nothing gets stricter. Where the
    /// text really does repeat itself, the window grows until it does not.
    ///
    /// Folded, because the folded text is what `landed` compares. Capped at the
    /// whole text before the span — at which point the leading context reaches
    /// the start of the value, and `atStart` says so rather than pretending a
    /// contains still places it.
    private func fragment(
        around range: Range<String.Index>, replacement: String, in updated: String
    ) -> Fragment {
        let before = content[..<range.lowerBound]
        let beforeCount = before.count
        let trailing = String(content[range.upperBound...].prefix(12))
        let target = folded(updated)

        var context = 12
        while true {
            let leading = String(before.suffix(context))
            // Nothing left to widen with, so the value's own start is the
            // anchor. This is also the span that begins the field, where there
            // is no leading context at all and a contains would accept the same
            // words written anywhere further down.
            if context >= beforeCount {
                return Fragment(text: leading + replacement + trailing, atStart: true)
            }
            if standsAlone(folded(leading), in: target) {
                return Fragment(text: leading + replacement + trailing, atStart: false)
            }
            context *= 2
        }
    }

    /// The text the value must hold for the edit to have happened, and where.
    private struct Fragment {
        let text: String
        /// The leading context reaches the start of the content, so the value
        /// has to *begin* with this. Containing it is not enough: a span at
        /// offset zero has nothing in front of it to be recognised by, and an
        /// identical run later in the field would answer for it.
        let atStart: Bool
    }

    /// Whether `needle` stands in exactly one place in `text`.
    private func standsAlone(_ needle: String, in text: String) -> Bool {
        guard !needle.isEmpty, let first = text.range(of: needle) else { return false }
        return text.range(of: needle, range: first.upperBound..<text.endIndex) == nil
    }

    private func landed(_ fragment: Fragment, needle: String) -> Bool {
        guard let value = SelectionReader.visibleText(of: element) else { return false }
        let text = folded(value)
        guard fragment.atStart else { return text.contains(needle) }
        // Leading whitespace on both sides, because a rich-text editor can put
        // a blank line above what it holds and that is not a failed write.
        return text.drop(while: \.isWhitespace)
            .starts(with: needle.drop(while: \.isWhitespace))
    }

    /// Typographic substitution is not a failed write. Most apps turn a straight
    /// apostrophe curly as it arrives, so "they're" comes back as "they’re" — the
    /// edit landed, and a literal comparison would call it a refusal.
    private func folded(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.utf8.count)
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            switch scalar {
            case "\u{2019}", "\u{2018}":
                result.append("'")
            case "\u{201C}", "\u{201D}":
                result.append("\"")
            // What a rich-text editor does to text on the way in. Outlook and
            // Mail put non-breaking spaces around pasted runs and keep carriage
            // returns in the value; both make a literal comparison fail on text
            // that is plainly correct on screen.
            case "\u{00A0}", "\u{202F}":
                result.append(" ")
            case "\r":
                result.append("\n")
                // A lone \r folds to \n same as \r\n does, so the \n that
                // follows a \r must not also fold — otherwise \r\n becomes \n\n.
                if index < scalars.endIndex, scalars[index] == "\n" {
                    index = scalars.index(after: index)
                }
            default:
                result.append(scalar)
            }
        }
        return String(result)
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
    /// Three ways it can answer, in descending order of how much they prove.
    ///
    /// The selected *text* is the strongest and is tried first. A native field
    /// gives it, and so does Slack — it named "est tunday morning works " for a
    /// selection asked for one character earlier, which is the whole reason
    /// this function exists. Chromium hands back `""` for a contenteditable
    /// whose selection was set through the accessibility API, so insisting on
    /// text alone would refuse every browser.
    ///
    /// Then the characters at the range, via `AXStringForRange`. Asked in the
    /// app's own numbers, so it says what the app took those numbers to mean —
    /// which is the question, because an app's offsets need not address its own
    /// value and the same numbers can name different characters.
    ///
    /// Then the *range* alone, for an app that implements neither. A range that
    /// reads back as the one asked for, when the one before it was different,
    /// is the app saying it moved the selection — and nothing more than that.
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
        let foldedExpected = folded(expected)
        repeat {
            if let selected = SelectionReader.selectedText(of: element), !selected.isEmpty {
                if folded(selected).compare(
                    foldedExpected, options: .caseInsensitive
                ) == .orderedSame {
                    return true
                }
                lastSeen = "\"\(selected.prefix(40))\""
            } else if let echoed = SelectionReader.selectedRange(of: element) {
                // No selected text to check, so the range is all there is —
                // and a range that reads back as the one asked for is weaker
                // evidence than it looks. An app's offsets need not address its
                // own value, so the same numbers can name different characters:
                // Slack echoed 62+25 for a selection holding the characters at
                // 63, and this said yes.
                //
                // `AXStringForRange` closes that without having to work out
                // where the selection really is. It is asked in the app's own
                // numbers — the same ones `select` passed it — so it answers
                // with the characters the app took those numbers to mean. If
                // they are not the ones intended, the selection is somewhere
                // else, whatever the numbers say.
                if echoed.location == range.location, echoed.length == range.length {
                    guard let said = SelectionReader.string(
                        of: element, at: range.location, length: range.length
                    ) else {
                        // Not implemented. The numbers are all there is, which
                        // is where this stood before.
                        return true
                    }
                    if folded(said).compare(
                        foldedExpected, options: .caseInsensitive
                    ) == .orderedSame {
                        return true
                    }
                    lastSeen = "\(echoed.location)+\(echoed.length), holding"
                        + " \"\(said.prefix(40))\""
                } else {
                    lastSeen = "\(echoed.location)+\(echoed.length)"
                }
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
    private func writeScreen(updated: String, undo: Undo) -> Outcome {
        guard let config = try? ConfigStore.load(), config.transcription.rewriteLine else {
            return .refused("rewrite_line is off, so terminals cannot be edited")
        }
        guard clearedBox() else {
            return .refused("could not empty the line; not retyping over what is left")
        }

        TextInserter.insert(updated, mode: .paste)
        if box(reads: updated) {
            Log.write("surface: retyped \(updated.count) chars of input line")
            return .replaced(undo)
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
    /// Clears the input line, and says whether it managed to.
    ///
    /// Two strategies, because one is not enough. Ctrl-A then Ctrl-K is the
    /// usual pair. When two reads in a row come back identical the keys are
    /// not landing where that pair assumes, and a third try at the same thing
    /// is waste — so the line is killed backwards from its end instead.
    ///
    /// Measured on a live Claude Code session: the pair left the box unchanged
    /// for all 12 attempts and the edit fell through to the clipboard, three
    /// times on 2026-08-27. What the box held was not recorded, which is why
    /// it is recorded now.
    private func clearedBox() -> Bool {
        var previous: String?
        var stalls = 0
        var backwards = false

        for _ in 0..<12 {
            guard let box = boxContent() else {
                Log.write("surface: cannot read the input box back; refusing to clear blind")
                return false
            }
            if box.isEmpty { return true }

            if box == previous {
                stalls += 1
                if stalls >= 2 {
                    guard !backwards else { return stuck(on: box) }
                    backwards = true
                    stalls = 0
                }
            } else {
                stalls = 0
            }
            previous = box

            if backwards {
                SelectionReader.postControlKey(0x0E)   // Ctrl-E, end of line
                Thread.sleep(forTimeInterval: 0.06)
                SelectionReader.postControlKey(0x20)   // Ctrl-U, kill to start
            } else {
                SelectionReader.postControlKey(0x00)   // Ctrl-A, start of line
                Thread.sleep(forTimeInterval: 0.06)
                SelectionReader.postControlKey(0x28)   // Ctrl-K, kill to end
            }
            Thread.sleep(forTimeInterval: 0.12)
        }

        if boxIsEmpty() == true { return true }
        return stuck(on: boxContent() ?? "")
    }

    /// The box would not empty. Says what it holds, so the next one of these
    /// is diagnosable from the log alone.
    private func stuck(on box: String) -> Bool {
        Log.write("surface: the box will not empty; it still reads \"\(box.prefix(80))\"")
        return false
    }

    private func boxContent() -> String? {
        guard let value = SelectionReader.visibleText(of: element) else { return nil }
        return SelectionReader.joinedInputBox(in: value)
    }

    private func boxIsEmpty() -> Bool? {
        boxContent().map { $0.isEmpty }
    }

    /// Whether the box now holds exactly the text we retyped.
    ///
    /// Equality, not containment. A box reading "Jery is on vacationJerry is on
    /// vacation" *contains* the corrected line, and containment is what reported
    /// that append as a clean retype for as long as this bug existed.
    private func box(reads expected: String) -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        let foldedExpected = folded(expected)
        repeat {
            if let value = SelectionReader.visibleText(of: element),
               let box = SelectionReader.joinedInputBox(in: value),
               folded(box) == foldedExpected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }
}
