import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A text field's whole text and its selection, for the loop's `at`,
/// `caret` and `select`.
///
/// The walk never reads a text area's value. Measured 09-25: TextEdit and a
/// Chrome contenteditable both hold their whole text in AXValue, with one
/// "\n" per paragraph.
enum TextCaret {

    static let fieldRoles: Set<String> = [
        kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// The field at `box`: the focused element when it lies over the box,
    /// else the text element under the box's centre or its nearest text
    /// ancestor. With no box, the focused element.
    static func field(ofApp name: String, box: CGRect?) -> AXUIElement? {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        let focused = attribute(app, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        guard let box else { return focused }
        if let focused, let frame = frame(of: focused), frame.insetBy(dx: -2, dy: -2)
            .contains(CGPoint(x: box.midX, y: box.midY)) {
            return focused
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            app, Float(box.midX), Float(box.midY), &hit) == .success, var element = hit
        else { return nil }
        for _ in 0..<12 {
            if fieldRoles.contains(role(element)) { return element }
            guard let parent = attribute(element, kAXParentAttribute) else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    static func isFocused(_ element: AXUIElement, ofApp name: String) -> Bool {
        guard let focused = field(ofApp: name, box: nil) else { return false }
        return CFEqual(focused, element)
    }

    /// (text, where it came from): "value", "range" or "children".
    static func text(of element: AXUIElement) -> (String, String) {
        if let value = string(attribute(element, kAXValueAttribute)), !value.isEmpty {
            return (value, "value")
        }
        if let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int, count > 0 {
            var whole = CFRange(location: 0, length: count)
            var out: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                AXValueCreate(.cfRange, &whole)!, &out) == .success,
               let text = string(out), !text.isEmpty {
                return (text, "range")
            }
        }
        let joined = children(element)
        return (joined, joined.isEmpty ? "none" : "children")
    }

    private static func children(_ element: AXUIElement, depth: Int = 0) -> String {
        guard depth < 20, let kids = attribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return "" }
        var parts: [String] = []
        for kid in kids {
            if role(kid) == kAXStaticTextRole, let value = string(attribute(kid, kAXValueAttribute)) {
                parts.append(value)
                continue
            }
            let inner = children(kid, depth: depth + 1)
            if !inner.isEmpty { parts.append(inner) }
        }
        return parts.joined(separator: depth == 0 ? "\n" : "")
    }

    /// Selects `expect`, which the field holds at `location` (UTF-16, as read
    /// by `text(of:)`), then leaves the caret before or after it when `caret`
    /// says so. Through AXSelectedTextRange when the field takes it, else by
    /// keys. Checked by reading the selection back.
    static func select(
        _ field: AXUIElement, location: Int, length: Int, expect: String, caret: String?
    ) -> [String: Any] {
        let whole = text(of: field).0 as NSString
        guard location >= 0, length > 0, location + length <= whole.length,
              whole.substring(with: NSRange(location: location, length: length)) == expect
        else { return ["error": "the field changed since it was read"] }
        if settable(field) {
            // Measured 09-25 in Chrome: AXValue has one "\n" per paragraph,
            // and AXSelectedTextRange counts none.
            let breaks = whole.substring(to: location).filter(\.isNewline).count
            let inside = expect.filter(\.isNewline).count
            for (start, count) in [(location, length), (location - breaks, length - inside)]
            where start >= 0 {
                guard setRange(field, start, count), same(selectedText(field), expect) else { continue }
                guard let caret else { return ["ok": true, "method": "ax"] }
                let at = caret == "before" ? start : start + count
                if setRange(field, at, 0), let now = selectedRange(field), now.location == at, now.length == 0 {
                    return ["ok": true, "method": "ax"]
                }
            }
        }
        return byKeys(field, before: whole.substring(to: location), whole: whole as String,
                      expect: expect, caret: caret)
    }

    /// ⌘↑ and → from the start, or ⌘↓ and ← from the end, one press per
    /// character; then ⇧→ over the words. Measured 09-25: option+→ stops at
    /// punctuation in Chrome and not in TextEdit, so words cannot be counted.
    private static func byKeys(
        _ field: AXUIElement, before: String, whole: String, expect: String, caret: String?
    ) -> [String: Any] {
        let fromStart = before.count, fromEnd = whole.count - before.count
        guard min(fromStart, fromEnd) + expect.count <= maxPresses else {
            return ["error": "too far to move by keys: \(min(fromStart, fromEnd)) characters"]
        }
        if fromStart <= fromEnd {
            ScreenAction.press(CGKeyCode(kVK_UpArrow), flags: .maskCommand)
            ScreenAction.repeatKey(CGKeyCode(kVK_RightArrow), times: fromStart)
        } else {
            ScreenAction.press(CGKeyCode(kVK_DownArrow), flags: .maskCommand)
            ScreenAction.repeatKey(CGKeyCode(kVK_LeftArrow), times: fromEnd)
        }
        ScreenAction.repeatKey(CGKeyCode(kVK_RightArrow), flags: .maskShift, times: expect.count)
        let selected = selectedText(field)
        guard same(selected, expect) else {
            return ["error": selected.map { "the keys selected \u{201c}\($0.prefix(40))\u{201d}, not \u{201c}\(expect.prefix(40))\u{201d}" }
                ?? "the keys ran, and the field does not say what is selected"]
        }
        if let caret {
            ScreenAction.press(CGKeyCode(caret == "before" ? kVK_LeftArrow : kVK_RightArrow))
        }
        return ["ok": true, "method": "keys"]
    }

    /// 2,000 presses take about 8 s.
    static let maxPresses = 2000

    /// Chrome's selected text drops the paragraph breaks.
    private static func same(_ selected: String?, _ expect: String) -> Bool {
        guard let selected else { return false }
        return selected.filter { !$0.isNewline } == expect.filter { !$0.isNewline }
    }

    private static func settable(_ field: AXUIElement) -> Bool {
        var can: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(
            field, kAXSelectedTextRangeAttribute as CFString, &can) == .success && can.boolValue
    }

    private static func setRange(_ field: AXUIElement, _ location: Int, _ length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        let done = AXUIElementSetAttributeValue(
            field, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &range)!) == .success
        usleep(50_000)
        return done
    }

    private static func selectedRange(_ field: AXUIElement) -> CFRange? {
        guard let value = attribute(field, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        return range
    }

    private static func selectedText(_ field: AXUIElement) -> String? {
        string(attribute(field, kAXSelectedTextAttribute))
    }

    static func role(_ element: AXUIElement) -> String {
        string(attribute(element, kAXRoleAttribute)) ?? ""
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ value: AnyObject?) -> String? {
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }
}
