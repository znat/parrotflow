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
    }

    static func read() -> Selection? {
        let owner = NSWorkspace.shared.frontmostApplication

        if let text = viaAccessibility(), !text.isEmpty {
            return Selection(text: text, owner: owner)
        }
        if let text = viaCopy(), !text.isEmpty {
            return Selection(text: text, owner: owner)
        }
        return nil
    }

    // MARK: - Accessibility attribute

    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success else { return nil }

        guard let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selected
        ) == .success else { return nil }

        return selected as? String
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

    /// Types the corrected spelling over whatever is selected.
    static func replaceSelection(with text: String, in owner: NSRunningApplication?) {
        owner?.activate()

        // Give the app a moment to come forward and restore its selection
        // before the paste lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            TextInserter.insert(text, mode: .paste)
        }
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
