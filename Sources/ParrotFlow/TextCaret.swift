import AppKit
import ApplicationServices

/// A text field's whole text, read for the loop's `at` and its checks.
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
