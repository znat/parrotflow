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

        // Some fields expose AXValue read-only and only accept text through the
        // keyboard. The range is already selected at this point, so a paste
        // lands exactly on it — this is the one case where Cmd-V is safe,
        // because we put the selection there ourselves a moment ago.
        Log.write("rewrite: \(roleName) ignored the direct write, trying paste over the selection")
        TextInserter.insert(replacement, mode: .paste)
        Thread.sleep(forTimeInterval: 0.2)

        if changed(element, from: text) { return true }
        Log.write("rewrite: \(roleName) would not accept either method")
        return false
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
