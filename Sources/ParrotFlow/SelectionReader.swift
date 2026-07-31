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
        if writeStatus == .success, changed(element, from: text) {
            return true
        }

        // Only paste once the selection is confirmed to exist. Setting the
        // range can report success and do nothing — terminals expose their
        // value as a read-only view of the screen — and pasting into that
        // means Cmd-V inserts at the caret instead of replacing. That appends
        // the correction to the end of the line: "Versalailles.Tasmeen".
        guard let selected = selectedText(of: element),
              selected.compare(needle, options: .caseInsensitive) == .orderedSame else {
            Log.write("rewrite: \(roleName) ignored the range; not pasting blind")
            return false
        }

        Log.write("rewrite: \(roleName) ignored the direct write, pasting over the confirmed selection")
        TextInserter.insert(replacement, mode: .paste)
        Thread.sleep(forTimeInterval: 0.2)

        if changed(element, from: text) { return true }
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
    /// So no diffing. The value is used only when it is plainly a field and not
    /// a screen — no newlines, and short. Then the corrected text is known
    /// exactly before a single key is pressed, and the keystrokes have nothing
    /// to infer.
    @discardableResult
    static func rewriteCurrentLine(
        applying rules: [(heard: String, corrected: String)],
        in element: AXUIElement
    ) -> Bool {
        guard let value = visibleText(of: element) else { return false }

        guard !value.contains("\n"), value.count <= 2000 else {
            Log.write("rewrite: value is \(value.count) chars of screen, not one line; not retyping")
            return false
        }

        let corrected = applying(rules, to: value)
        guard corrected != value else {
            Log.write("rewrite: no rule matched the line; leaving it alone")
            return false
        }

        postControlKey(0x00)   // Ctrl-A, start of line
        Thread.sleep(forTimeInterval: 0.06)
        postControlKey(0x28)   // Ctrl-K, kill to end of line
        Thread.sleep(forTimeInterval: 0.10)

        TextInserter.insert(corrected, mode: .paste)
        Thread.sleep(forTimeInterval: 0.20)

        // If the line is not what we meant to write, the kill or the paste
        // missed. Ctrl-Y yanks back what Ctrl-K took, which is the only undo
        // that does not depend on the accessibility API being truthful.
        let after = visibleText(of: element) ?? ""
        if after.contains(corrected) {
            Log.write("rewrite: retyped \(value.count) chars with \(rules.count) rule(s) applied")
            return true
        }
        Log.write("rewrite: line did not come back as expected; yanking it back")
        postControlKey(0x10)   // Ctrl-Y
        return false
    }

    /// The text present in `before` but not `after`, found by trimming the
    /// common prefix and suffix. A line kill removes one contiguous run, so
    /// what is left in the middle is exactly what went.
    static func removedSegment(before: String, after: String) -> String? {
        guard before.count > after.count else { return nil }
        let b = Array(before), a = Array(after)

        var head = 0
        while head < a.count, b[head] == a[head] { head += 1 }

        var tail = 0
        while tail < a.count - head, b[b.count - 1 - tail] == a[a.count - 1 - tail] { tail += 1 }

        let start = head, end = b.count - tail
        guard start < end else { return nil }
        return String(b[start..<end])
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

    private static func changed(_ element: AXUIElement, from original: String) -> Bool {
        var after: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &after
        ) == .success, let updated = after as? String else { return false }
        return updated != original
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
