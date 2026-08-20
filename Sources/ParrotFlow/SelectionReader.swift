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
    static func inputLine(anchoredBy dictated: String?, in screen: String) -> String? {
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

    static func postControlKey(_ key: CGKeyCode) {
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

    /// The accessibility role of an element — `AXTextArea`, `AXWebArea`, and so
    /// on — or nil when it will not say.
    static func role(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &role
        ) == .success else { return nil }
        return role as? String
    }

    /// Whether an element would take text typed into it.
    ///
    /// Settability first, role second, and that order is the point. A role is
    /// what an app calls its own view, and the apps that matter call theirs
    /// whatever the page said — an Electron composer and a browser field are
    /// `AXTextArea` on a good day and something invented on the others. What
    /// every real input has in common is that its text can be written, and
    /// `AXUIElementIsAttributeSettable` answers that about a custom role as
    /// readily as about a stock one.
    ///
    /// The role check stays as a fallback rather than as the test, because the
    /// two mistakes are not the same size. A field wrongly called uneditable
    /// sends the dictation to the clipboard, which is the sentence not landing;
    /// a read-only text area wrongly called editable gets a ⌘V it ignores,
    /// which is what already happens today.
    static func acceptsTypedText(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.25)
        if isSettable(kAXValueAttribute as CFString, of: element) { return true }
        if isSettable(kAXSelectedTextAttribute as CFString, of: element) { return true }
        guard let role = role(of: element) else { return false }
        return editableRoles.contains(role)
    }

    /// Roles that are a text input whatever they answer about settability.
    ///
    /// `AXWebArea` is deliberately absent: it is the page itself, which is what
    /// a browser reports when you are reading rather than typing — the case
    /// this whole check exists to catch.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    private static func isSettable(_ attribute: CFString, of element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, attribute, &settable
        ) == .success else { return false }
        return settable.boolValue
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

    static func selectedRange(of element: AXUIElement) -> CFRange? {
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

    /// The characters the app says are at one of *its* offsets.
    ///
    /// The only read that crosses between the two coordinate spaces an app can
    /// have. `kAXValue` is one string and `kAXSelectedTextRange` is a number,
    /// and nothing says the number addresses the string — in Chromium it does
    /// not, and the gap grows by one for every block boundary above the offset.
    /// This asks in the app's own numbers and answers in characters, so the two
    /// can be lined up by comparison instead of by assumption.
    ///
    /// Nil when the app does not implement it, which is most of them. That is
    /// not a failure: an app whose offsets already address its value has
    /// nothing to translate.
    static func string(of element: AXUIElement, at location: Int, length: Int) -> String? {
        guard location >= 0, length > 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var answer: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &answer
        ) == .success else { return nil }
        return answer as? String
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

    static func postCommandKey(_ key: CGKeyCode) {
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
