import AppKit
import ApplicationServices

/// Reads whatever text is selected in the frontmost app.
///
/// Two strategies, because neither works everywhere:
///
/// - `kAXSelectedTextAttribute` is clean and leaves the pasteboard alone, but
///   plenty of apps don't implement it — Electron and most browsers return
///   nothing.
/// - Synthesising ⌘C works almost everywhere, at the cost of borrowing the
///   pasteboard. Used only when the accessibility attribute comes up empty.
///
/// Both need the Accessibility permission.
enum SelectionReader {

    struct Selection {
        let text: String
        /// The app the text came from, so focus can be handed back.
        let owner: NSRunningApplication?
        /// The text element and the exact character range that was selected.
        /// Kept so the correction can be written back to that range rather
        /// than pasted at wherever the caret happens to be afterwards.
        var element: AXUIElement?
        var range: CFRange?
    }

    /// Cheap, side-effect-free read. Safe to call on every hotkey press.
    ///
    /// Terminal selections are cleared by all sorts of things — a keystroke,
    /// losing focus — so by the time a transcript comes back the selection may
    /// be long gone. Snapshotting at press time is the only reliable moment.
    static func snapshot() -> Selection? {
        guard Permissions.accessibility == .granted else { return nil }
        guard let element = focusedElement() else { return nil }
        guard let text = selectedText(of: element), !text.isEmpty else { return nil }
        return Selection(
            text: text,
            owner: NSWorkspace.shared.frontmostApplication,
            element: element,
            range: selectedRange(of: element)
        )
    }

    /// The focused text element and its owning app, with no selection needed.
    ///
    /// Captured at hotkey press so a rule learned by voice can still fix the
    /// word already sitting in the field — there was never a selection to
    /// snapshot, only a transcript that got typed there a moment ago.
    static func focusSnapshot() -> Selection? {
        guard Permissions.accessibility == .granted else { return nil }
        guard let element = focusedElement() else { return nil }
        return Selection(
            text: "",
            owner: NSWorkspace.shared.frontmostApplication,
            element: element,
            range: nil
        )
    }

    /// Rewrites the last occurrence of `needle` in a text element.
    ///
    /// Last rather than first: the word being corrected was dictated a moment
    /// ago, so the most recent occurrence is the one meant. Replaces just that
    /// range instead of rewriting the whole field, which would lose the caret
    /// and clobber anything typed since.
    @discardableResult
    static func replaceLastOccurrence(
        of needle: String,
        with replacement: String,
        in element: AXUIElement
    ) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.5)

        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleName = (role as? String) ?? "unknown"

        var value: CFTypeRef?
        let readStatus = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        )
        guard readStatus == .success, let text = value as? String, !text.isEmpty else {
            Log.write("rewrite: can't read \(roleName) value (AXError \(readStatus.rawValue))")
            return false
        }
        Log.write("rewrite: \(roleName), \(text.count) chars, looking for \"\(needle)\"")

        guard let found = text.range(of: needle, options: [.caseInsensitive, .backwards]) else {
            let preview = text.suffix(160).replacingOccurrences(of: "\n", with: "⏎")
            Log.write("rewrite: \"\(needle)\" not in \(roleName); tail = \"\(preview)\"")
            return false
        }

        // The replacement in the company it is supposed to keep. Checking for
        // the replacement on its own would accept an append — "…the
        // storethey're" contains "they're" quite happily — so the surrounding
        // characters are what make this a check rather than a formality.
        let context = 12
        let fragment = String(text[..<found.lowerBound].suffix(context))
            + replacement
            + String(text[found.upperBound...].prefix(context))

        let nsRange = NSRange(found, in: text)
        var range = CFRange(location: nsRange.location, length: nsRange.length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return false }

        let selectStatus = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, axRange
        )
        guard selectStatus == .success else {
            Log.write("rewrite: \(roleName) refused the selection (AXError \(selectStatus.rawValue))")
            return false
        }

        let writeStatus = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef
        )
        if writeStatus == .success, landed(element, expecting: fragment) {
            return true
        }

        // Everything past here is the paste fallback, which is only safe where
        // the value is an editable buffer. A terminal's is a view of its
        // screen: setting the range really does select the characters drawn
        // there, but the program on the other side of the pty never hears
        // about it, so Cmd-V arrives at the input caret and appends —
        // "…the storethey're", the same shape as "Versalailles.Tasmeen".
        //
        // The guard below used to be the only one, and it could not catch that,
        // because it asked whether the selection existed. It did: we had just
        // made it two lines earlier. Confirming your own action is not
        // evidence, so the check passed every time while the paste corrupted
        // the line. What rules a terminal out is the shape of the value.
        guard !text.contains("\n"), text.count <= 2000 else {
            Log.write("rewrite: \(roleName) is a screen, not a field — its selection is of output, not input; not pasting")
            return false
        }

        guard let selected = selectedText(of: element),
              selected.compare(needle, options: .caseInsensitive) == .orderedSame else {
            Log.write("rewrite: \(roleName) ignored the range; not pasting blind")
            return false
        }

        Log.write("rewrite: \(roleName) ignored the direct write, pasting over the confirmed selection")
        TextInserter.insert(replacement, mode: .paste)
        Thread.sleep(forTimeInterval: 0.2)

        if landed(element, expecting: fragment) { return true }
        Log.write("rewrite: \(roleName) would not accept either method")
        return false
    }

    /// Clears the current input line with readline keys and types a corrected
    /// version, checking between the two that the clear actually happened.
    ///
    /// The last resort for surfaces the accessibility API cannot write —
    /// terminals, mostly, whose AX value is a read-only view of the screen.
    /// Keystrokes work there because accepting keystrokes is what a terminal
    /// is for.
    ///
    /// Ctrl-A then Ctrl-K is the readline idiom for "clear this line", and it
    /// works on the logical line, so a wrapped one is handled correctly.
    ///
    /// The keystrokes are blind, but their effect is not: reading the field
    /// back after the kill turns this from a hope into a check. If the text is
    /// still there the kill did not land, and nothing is typed — Ctrl-A alone
    /// only moved the caret, so bailing costs nothing. Pasting at that point
    /// is what appends "…Versalailles.Tasmeen" to the end of a line.
    /// Clears the input line, works out what was in it from what disappeared,
    /// and types back a corrected version.
    ///
    /// The last resort for surfaces the accessibility API cannot write —
    /// terminals, whose AX value is a read-only view of the screen. Keystrokes
    /// work there because accepting keystrokes is what a terminal is.
    ///
    /// Identifying "the current line" inside a screen-shaped value is not
    /// reliable: a wrapped line arrives split across newlines, and the text may
    /// have been edited since we dictated it. So the line is not identified in
    /// advance at all — it is killed, and the difference between the screen
    /// before and after says exactly what was there. That text is authoritative
    /// because the terminal just gave it to us.
    ///
    /// If nothing was killed, nothing is typed. If something was, it is always
    /// typed back — corrected when a rule applies, verbatim when none does —
    /// so the line is never left emptied.
    /// Clears the input line, works out what was in it from what disappeared,
    /// and types back a corrected version — restoring it if anything is unclear.
    ///
    /// The last resort for surfaces the accessibility API cannot write.
    /// Keystrokes work in a terminal because accepting keystrokes is what a
    /// terminal is.
    ///
    /// The line is not identified in advance: it is killed, and the difference
    /// between the screen before and after says what was there. But that read
    /// cannot be trusted to prove the kill happened — a terminal's AX value can
    /// report the line unchanged while the screen shows it gone, which once
    /// left an input emptied because we concluded there was nothing to restore.
    ///
    /// So the safety net is readline's own: Ctrl-K pushes to the kill ring and
    /// Ctrl-Y yanks it back. Any uncertainty ends in Ctrl-Y, which puts the
    /// line back whatever the accessibility API believes.
    /// Applies rules to a line, falling back to the closest match.
    ///
    /// The word on screen and the word in the rule are two hearings of the
    /// same name and often differ: a field reading "I love versall" against a
    /// rule for "Versailles" matched nothing, so the correction silently did
    /// not happen. The target spelling is known and correct, so the word to
    /// replace is whatever in the line most resembles it.
    static func applying(
        _ rules: [(heard: String, corrected: String)],
        to line: String
    ) -> String {
        var output = line
        for rule in rules {
            if let pattern = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: rule.heard))\\b",
                options: [.caseInsensitive]
            ), pattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil {
                output = pattern.stringByReplacingMatches(
                    in: output,
                    range: NSRange(output.startIndex..., in: output),
                    withTemplate: NSRegularExpression.escapedTemplate(for: rule.corrected)
                )
                continue
            }

            // Not there verbatim — find what the correct spelling resembles.
            guard let nearest = VoiceCommand.closestWord(to: rule.corrected, in: output),
                  nearest.lowercased() != rule.corrected.lowercased(),
                  let pattern = try? NSRegularExpression(
                      pattern: "\\b\(NSRegularExpression.escapedPattern(for: nearest))\\b",
                      options: [.caseInsensitive]
                  )
            else { continue }

            Log.write("rewrite: \"\(rule.heard)\" not present; closest is \"\(nearest)\"")
            output = pattern.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.corrected)
            )
        }
        return output
    }

    /// Retypes the input line corrected, when the field's value is readable
    /// and is the line itself rather than a screenful of terminal.
    ///
    /// The last resort for surfaces that refuse accessibility writes but accept
    /// keystrokes. Reading works in those; only writing does not.
    ///
    /// An earlier version killed the line and diffed the screen before and
    /// after to learn what had been there. That cannot work against a live TUI:
    /// Claude Code redrew its status bar between the two reads and the diff
    /// swept up 140 characters of chrome for an 18 character line, which then
    /// got typed into the input.
    ///
    /// So no diffing, and nothing is read out of a screen. In a plain field the
    /// value is the line and can be used directly. In a terminal it cannot be,
    /// but it does not need to be: the line was dictated there a moment ago and
    /// we still have what we typed. The corrected text is known exactly before
    /// a single key is pressed, and the screen is asked one question only —
    /// whether the line is still ours alone — which is weak enough that it can
    /// answer honestly.
    @discardableResult
    static func rewriteCurrentLine(
        applying rules: [(heard: String, corrected: String)],
        dictated: String? = nil,
        in element: AXUIElement
    ) -> Bool {
        rewriteCurrentLine(dictated: dictated, in: element) { applying(rules, to: $0) }
    }

    /// The same retype, told what to do to the line rather than which rules to
    /// run over it.
    ///
    /// Rules match on word boundaries, which is right for correcting a word and
    /// wrong for replacing a phrase: `\b` will not match after the full stop in
    /// "Sixty Euros.", so a transform asked to rewrite that found nothing and
    /// its result was pasted alongside instead.
    @discardableResult
    static func rewriteCurrentLine(
        dictated: String?,
        in element: AXUIElement,
        correcting: (String) -> String
    ) -> Bool {
        guard let value = visibleText(of: element) else { return false }

        let line: String
        if !value.contains("\n"), value.count <= 2000 {
            line = value
        } else if let located = inputLine(anchoredBy: dictated, in: value) {
            Log.write("rewrite: value is a screen; using the input box")
            line = located
        } else {
            Log.write("rewrite: \(value.count) chars of screen and the line is not ours alone; not retyping")
            return false
        }

        let corrected = correcting(line)
        guard corrected != line else {
            Log.write("rewrite: nothing to change on the line; leaving it alone")
            return false
        }

        guard clearedInput(of: element) else {
            Log.write("rewrite: could not empty the line; not retyping over what is left")
            return false
        }
        TextInserter.insert(corrected, mode: .paste)

        // Poll, rather than read once after a guessed delay. The terminal
        // services the paste asynchronously and repaints when it is ready, and
        // a single read at 0.2s arrived before the repaint: the line was
        // already right, the check said it was not, and the restore below
        // undid a correction that had worked. `viaCopy` learned this first.
        if appeared(corrected, in: element, within: 1.5) {
            Log.write("rewrite: retyped \(line.count) chars")
            return true
        }

        // Put it back deliberately rather than with Ctrl-Y. The paste has
        // already happened by now, so yanking inserts what Ctrl-K took *after*
        // whatever landed and leaves you holding both — which is how a
        // truncated correction became a duplicated line. We still have the text
        // that was there, so type that instead and depend on nothing.
        Log.write("rewrite: line did not come back as expected; restoring what was there")
        _ = clearedInput(of: element)
        TextInserter.insert(line, mode: .paste)
        Thread.sleep(forTimeInterval: 0.20)
        return false
    }

    /// Waits for text to show up on screen, or gives up.
    ///
    /// The wait is the point: everything this class writes is written by
    /// posting a keystroke, and a keystroke is a request. Reading back before
    /// the app has serviced it does not measure the write, it measures the
    /// delay — and concluding failure from that is worse than not checking,
    /// because the recovery then destroys work that was fine.
    private static func appeared(
        _ text: String, in element: AXUIElement, within seconds: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let value = visibleText(of: element) {
                // The raw screen first, then the input box put back together.
                // A corrected line long enough to wrap is drawn across several
                // rows and never appears whole in the value — which reported a
                // retype that had plainly worked as a failure, and undid it.
                if value.contains(text) { return true }
                if let joined = joinedInputBox(in: value), joined.contains(text) { return true }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    /// The input line, located by text we know we put on it.
    ///
    /// The transcript answers "which row", never "what is on it". Those are
    /// very different questions and only the first one is safe to ask of a
    /// transcript: a field can hold several dictations and whatever was typed
    /// between them, so retyping the last transcript would quietly delete the
    /// rest of the line. The row itself is authoritative about its own
    /// contents, and it is authoritative about all of them.
    ///
    /// Nor is this the read that failed before. That one diffed whole screens
    /// before and after and swept up 140 characters of status bar for an 18
    /// character line. This reads one row, and only ever the row that already
    /// contains text we placed there.
    private static func inputLine(anchoredBy dictated: String?, in screen: String) -> String? {
        let rows = screen.components(separatedBy: "\n")

        // The input box: what lies between the last two rules the TUI draws.
        //
        // A wrapped line occupies several rows of it, and refusing whenever a
        // line crossed the width made this useless in practice — two dictated
        // sentences reach the edge of an 80 column terminal, and every
        // correction after that was declined. So the rows are put back
        // together instead.
        //
        // Joined with a single space because that is what the break consumed:
        // a soft wrap happens at a space and the space is not drawn. The
        // reconstruction is checked before it is trusted — if the anchor is not
        // in the result, the rows did not go back together the way they came
        // apart, and this refuses rather than retyping a guess.
        // No anchor needed here. The box is identified by the rules drawn round
        // it, not by recognising its contents, and asking the transcript to
        // vouch for it was what broke: the app had recorded "So Georgie." as
        // the last dictation while the field held "…Georgie.So ", so the anchor
        // described text that was not there and a word plainly sitting in the
        // box went uncorrected.
        //
        // Nothing is risked by dropping it. The substitution decides whether
        // there is anything to do, and a box with no match in it is left alone
        // a few lines below.
        if let joined = joinedInputBox(in: screen), !joined.isEmpty {
            guard joined.count <= 2000 else {
                Log.write("rewrite: the input box holds \(joined.count) chars; not retyping")
                return nil
            }
            return joined
        }

        // Past here there is no box, so the line can only be identified by
        // recognising text we put there.
        guard let dictated, !dictated.isEmpty else {
            Log.write("rewrite: no input box, and no transcript to find the line by; not retyping")
            return nil
        }

        // No box drawn, or the anchor is not inside it. Fall back to a single
        // row, which is all that can be identified without one.
        guard let index = rows.indices.reversed().first(
            where: { rows[$0].contains(dictated) }
        ) else {
            Log.write("rewrite: nothing on screen anchors the transcript; not retyping")
            return nil
        }
        let row = rows[index]

        // Whether the line wrapped cannot be read off its own width. A terminal
        // soft-wraps at a word boundary, so a wrapped row stops short of the
        // edge and measures no differently from a line that simply ended —
        // which is how a 166 character line got retyped as its first 74 and the
        // rest of the sentence was left stranded below.
        //
        // The row underneath is what tells you. Under an unwrapped input it is
        // the box border; under a wrapped one it is the remainder of what was
        // being typed.
        let below = index + 1 < rows.count ? rows[index + 1] : ""
        guard below.trimmingCharacters(in: .whitespaces).isEmpty || isBorder(below) else {
            Log.write("rewrite: the row below has text on it; the line may have wrapped — not retyping")
            return nil
        }
        return stripPrompt(row)
    }

    /// Empties the input line, checking between presses rather than assuming.
    ///
    /// Ctrl-K kills to the end of the *visual row* in this TUI, not the end of
    /// the logical line, so a single press leaves behind everything a wrap
    /// pushed onto the rows below — and the retype then landed on top of the
    /// remainder: "…certainly wrapsthis line past the width…". Pressing until
    /// the box reads empty is the only version of this that survives a line
    /// that wrapped.
    ///
    /// Only where the box can be read. In a plain field there is nothing to
    /// check against, and a loop that cannot see what it is doing would keep
    /// killing; there, one press is what it always was.
    private static func clearedInput(of element: AXUIElement) -> Bool {
        func boxIsEmpty() -> Bool? {
            guard let value = visibleText(of: element),
                  let box = joinedInputBox(in: value) else { return nil }
            return box.isEmpty
        }

        guard boxIsEmpty() != nil else {
            postControlKey(0x00)   // Ctrl-A, start of line
            Thread.sleep(forTimeInterval: 0.06)
            postControlKey(0x28)   // Ctrl-K, kill to end of line
            Thread.sleep(forTimeInterval: 0.10)
            return true
        }

        for _ in 0..<12 {
            if boxIsEmpty() == true { return true }
            postControlKey(0x00)
            Thread.sleep(forTimeInterval: 0.06)
            postControlKey(0x28)
            Thread.sleep(forTimeInterval: 0.12)
        }
        return boxIsEmpty() == true
    }

    /// The input box put back into one line, needing no anchor to find it.
    ///
    /// Between the last two rules the TUI draws, joined with the single space
    /// each soft wrap consumed. Used to read the line before a retype and to
    /// check it afterwards — and it has to be both, because after the
    /// substitution the anchor is the one thing no longer on the line.
    static func joinedInputBox(in screen: String) -> String? {
        let rows = screen.components(separatedBy: "\n")
        let borders = rows.indices.filter { isBorder(rows[$0]) }
        guard borders.count >= 2 else { return nil }
        let lower = borders[borders.count - 1]
        let upper = borders[borders.count - 2]
        guard upper + 1 < lower else { return nil }
        return rows[(upper + 1)..<lower]
            .map(stripPrompt).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A rule the TUI drew, rather than anything anyone typed.
    static func isBorder(_ row: String) -> Bool {
        let bare = row.trimmingCharacters(in: .whitespaces)
        return !bare.isEmpty && bare.allSatisfy { "─━—-│┃|┌┐└┘├┤╭╮╰╯╌┄".contains($0) }
    }

    /// A row without the prompt or the padding the terminal drew around it.
    ///
    /// One glyph, not a run of them: dropping every leading `>` would eat a
    /// line that genuinely begins with one.
    private static func stripPrompt(_ row: String) -> String {
        var line = Substring(row).drop(while: { $0 == " " })
        if let first = line.first, "❯>$#%│⏵".contains(first) {
            line = line.dropFirst().drop(while: { $0 == " " })
        }
        return String(line).trimmingCharacters(in: .whitespaces)
    }

    private static func postControlKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// An element's whole value. In a terminal this is the visible screen,
    /// wrapping and all, which is why callers match against text they already
    /// hold rather than trying to identify "the current line" within it.
    static func visibleText(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        ) == .success, let text = value as? String else { return nil }
        return text
    }

    /// True when the correction is where it was asked to go.
    ///
    /// This used to ask whether the value had changed at all, which is not the
    /// same question and answered yes far too easily. A live TUI changes on its
    /// own — a clock in a status bar is enough — so a paste that appended
    /// "…the storethey're" and a paste that did nothing both reported success.
    /// What matters is that the text now reads the way it would have if the
    /// substitution had happened, in the place it was meant to happen, and an
    /// append does not.
    private static func landed(_ element: AXUIElement, expecting fragment: String) -> Bool {
        var after: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &after
        ) == .success, let updated = after as? String else { return false }
        return folded(updated).contains(folded(fragment))
    }

    /// Typographic substitution is not a failed write. Most apps turn a
    /// straight apostrophe curly as it arrives, so "they're" comes back as
    /// "they’re" — the correction landed, and a literal comparison would call
    /// it a refusal and send the text to the clipboard instead.
    private static func folded(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    /// Full read, in descending order of politeness. `snapshot` is preferred
    /// when one was taken; this is the fallback.
    static func read(fallbackTo pasteboard: Bool = true) -> Selection? {
        let owner = NSWorkspace.shared.frontmostApplication

        if let text = viaAccessibility(), !text.isEmpty {
            Log.write("selection via accessibility")
            return Selection(text: text, owner: owner)
        }
        if let text = viaCopy(), !text.isEmpty {
            Log.write("selection via synthetic copy")
            return Selection(text: text, owner: owner)
        }
        // Last resort: whatever the user copied themselves. Terminals in
        // particular drop their selection before we can read it, so "select,
        // copy, then say the phrase" is the workflow that always works.
        if pasteboard,
           let text = NSPasteboard.general.string(forType: .string),
           !text.isEmpty, text.count <= 200 {
            Log.write("selection via clipboard")
            return Selection(text: text, owner: owner)
        }
        return nil
    }

    // MARK: - Accessibility attribute

    private static func viaAccessibility() -> String? {
        guard let element = focusedElement() else { return nil }
        return selectedText(of: element)
    }

    /// True when the element belongs to ParrotFlow itself.
    ///
    /// Worth checking before writing anywhere: by the time a correction is
    /// confirmed, our own panel has held focus, and a stale or re-resolved
    /// element reference points at its text field rather than the user's.
    /// Editing that does nothing visible and looks like the target app
    /// refusing.
    static func isOurs(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    /// The focused element in a specific app, after handing focus back to it.
    ///
    /// Preferred over an element captured earlier: apps generally only honour
    /// writes to whatever currently has focus, and re-querying guarantees we
    /// are addressing that rather than a reference that has gone stale.
    static func refocusedElement(in owner: NSRunningApplication?) -> AXUIElement? {
        owner?.activate()
        Thread.sleep(forTimeInterval: 0.25)
        guard let element = focusedElement(), !isOurs(element) else { return nil }
        return element
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        // Without this the default timeout is ~6s, and these calls run on the
        // main thread on every hotkey press. One busy app — Xcode indexing, a
        // beachballing Electron window — and the hotkey appears dead because
        // the run loop is stuck waiting for it to answer.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
            let element = focused,
            CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    static func selectedText(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        ) == .success else { return nil }
        return selected as? String
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
            let wrapped = value,
            CFGetTypeID(wrapped) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(wrapped as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Synthetic copy

    private static func viaCopy() -> String? {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount

        postCommandKey(CGKeyCode(kVK_ANSI_C))

        // The target app services the keystroke asynchronously; poll briefly
        // rather than guessing at a single sleep duration.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if pasteboard.changeCount != previousChangeCount {
                return pasteboard.string(forType: .string)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    enum ReplaceOutcome {
        /// Written straight into the range that was selected.
        case written
        /// Pasted over a selection we confirmed still existed.
        case pasted
        /// Nothing was safe to do; the text is on the clipboard instead.
        case clipboardOnly
    }

    /// Puts the corrected text back, or refuses.
    ///
    /// Pasting blind is how you corrupt someone's document: if the selection
    /// has collapsed to a caret — which is what a terminal does the moment it
    /// loses focus — Cmd-V inserts instead of replacing, and you get
    /// "and TasTasmeen.min." out of "and Tasmin.". So: write to the recorded
    /// range if the element supports it, else paste only after confirming a
    /// selection is genuinely still there, else leave it on the clipboard.
    @discardableResult
    static func replaceSelection(with text: String, in selection: Selection) -> ReplaceOutcome {
        if let element = selection.element, writeDirectly(text, to: element, range: selection.range) {
            Log.write("correction written via accessibility range")
            return .written
        }

        selection.owner?.activate()
        // Let the app come forward before asking what it has selected.
        Thread.sleep(forTimeInterval: 0.15)

        if let element = focusedElement(),
           let current = selectedText(of: element), !current.isEmpty {
            Log.write("correction pasted over live selection")
            TextInserter.insert(text, mode: .paste)
            return .pasted
        }

        Log.write("selection gone; correction left on the clipboard")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .clipboardOnly
    }

    /// Restores the recorded range, then replaces its contents. No keystrokes,
    /// no dependence on the app having kept its selection visible.
    private static func writeDirectly(
        _ text: String,
        to element: AXUIElement,
        range: CFRange?
    ) -> Bool {
        if var range {
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            guard AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                value
            ) == .success else { return false }
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private static func postCommandKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private let kVK_ANSI_C: Int = 0x08
