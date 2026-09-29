import AppKit
import ApplicationServices

/// One accessibility element. Reads return nil when the attribute is missing
/// or empty; writes and actions throw.
public struct Element: Hashable, @unchecked Sendable {
    public let ref: AXUIElement

    public init(_ ref: AXUIElement) {
        self.ref = ref
    }

    public static func == (a: Element, b: Element) -> Bool { CFEqual(a.ref, b.ref) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(ref)) }

    // MARK: - Reading

    public func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success ? value : nil
    }

    /// Like `attribute`, but says why it failed. A missing value is nil, not an error.
    public func read(_ name: String) throws -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
        switch result {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw AXKitError.ax(result, "read \(name)")
        }
    }

    public func string(_ name: String) -> String? {
        guard let value = attribute(name) else { return nil }
        return Element.text(of: value)
    }

    public func bool(_ name: String) -> Bool? {
        (attribute(name) as? NSNumber)?.boolValue
    }

    public func element(_ name: String) -> Element? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Element(value as! AXUIElement)
    }

    public func elements(_ name: String) -> [Element] {
        (attribute(name) as? [AXUIElement] ?? []).map(Element.init)
    }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var roleDescription: String? { string(kAXRoleDescriptionAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    public var help: String? { string(kAXHelpAttribute) }
    public var placeholder: String? { string("AXPlaceholderValue") }
    public var identifier: String? { string(kAXIdentifierAttribute) }
    /// Chromium and Electron: the HTML `id`.
    public var domIdentifier: String? { string("AXDOMIdentifier") }
    public var domClasses: [String] { attribute("AXDOMClassList") as? [String] ?? [] }
    public var accessibilityDescription: String? { string(kAXDescriptionAttribute) }

    /// The first of title, description, placeholder and help that is not
    /// blank. Spotify's icon buttons have an empty title and the name in the
    /// description, so an empty attribute must not end the search.
    public var name: String? {
        [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute]
            .lazy.compactMap { string($0) }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public var value: AnyObject? { attribute(kAXValueAttribute) }
    public var valueText: String? { value.map(Element.text(of:)) }

    public var isEnabled: Bool? { bool(kAXEnabledAttribute) }
    public var isFocused: Bool? { bool(kAXFocusedAttribute) }
    public var isSelected: Bool? { bool(kAXSelectedAttribute) }
    public var isExpanded: Bool? { bool(kAXExpandedAttribute) }

    /// Screen coordinates, top-left origin.
    public var frame: CGRect? {
        guard let position = attribute(kAXPositionAttribute), let size = attribute(kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// The part of the frame that shows: cut by each scroll area and the
    /// window above it. A text view in a scroll view can be taller or offset
    /// from what shows, so its middle can fall outside it (09-28).
    public var visibleFrame: CGRect? {
        guard var shown = frame else { return nil }
        var current = parent
        for _ in 0..<40 {
            guard let element = current else { break }
            if [kAXScrollAreaRole, kAXWindowRole].contains(element.role ?? ""), let box = element.frame {
                shown = shown.intersection(box)
                if shown.isNull { return nil }
            }
            if element.role == kAXWindowRole { break }
            current = element.parent
        }
        return shown
    }

    public var children: [Element] { elements(kAXChildrenAttribute) }
    public var parent: Element? { element(kAXParentAttribute) }
    public var window: Element? { element(kAXWindowAttribute) }

    /// Inside a Chromium or WebKit page. Pages need other ways than native
    /// controls: see `Controls`.
    public var isInWebArea: Bool {
        var current = parent
        for _ in 0..<80 {
            guard let element = current else { return false }
            if element.role == "AXWebArea" { return true }
            current = element.parent
        }
        return false
    }

    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    public var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    public var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(ref, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    public func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(ref, name as CFString, &settable) == .success
            && settable.boolValue
    }

    /// The first descendant that matches, breadth first, reading at most `budget` elements.
    public func first(budget: Int = 5000, where match: (Element) -> Bool) -> Element? {
        var queue = children
        var next = 0
        while next < queue.count, next < budget {
            let element = queue[next]
            next += 1
            if match(element) { return element }
            queue.append(contentsOf: element.children)
        }
        return nil
    }

    /// The first descendant that matches, depth first, no deeper than
    /// `depth`. For a big tree where the element sits deep but not far down:
    /// Messages lists every conversation before its text field. Breadth first
    /// ran out of budget, and an unbounded walk read the whole transcript
    /// for more than 25 s (09-29).
    public func first(depth: Int, budget: Int = 20000, where match: (Element) -> Bool) -> Element? {
        var stack = children.reversed().map { ($0, 1) }
        var left = budget
        while let (element, level) = stack.popLast(), left > 0 {
            left -= 1
            if match(element) { return element }
            if level < depth { stack.append(contentsOf: element.children.reversed().map { ($0, level + 1) }) }
        }
        return nil
    }

    /// What the element shows: its value, else its title, else its first static text's value.
    public var shownText: String? {
        if let text = valueText, !text.isEmpty { return text }
        if let title, !title.isEmpty { return title }
        return first(budget: 50) { $0.role == kAXStaticTextRole }?.valueText
    }

    // MARK: - Acting

    /// A success does not mean the app did anything: check the result.
    public func perform(_ action: String) throws {
        let result = AXUIElementPerformAction(ref, action as CFString)
        guard result == .success else { throw AXKitError.ax(result, "perform \(action)") }
    }

    /// A success does not mean the value was taken: measured on checkboxes,
    /// radios, segments and pop-ups, which return success and change nothing.
    public func set(_ name: String, to value: AnyObject) throws {
        let result = AXUIElementSetAttributeValue(ref, name as CFString, value)
        guard result == .success else { throw AXKitError.ax(result, "set \(name)") }
    }

    /// How long one call to this element's app may block. 0 restores the default.
    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ref, seconds)
    }

    // MARK: -

    static func text(of value: AnyObject) -> String {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let number = value as? NSNumber { return number.stringValue }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let url = value as? URL { return url.absoluteString }
        return ""
    }
}
