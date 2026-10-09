import AppKit
import ApplicationServices

/// One element as a read saw it: plain values, no live reference. The text
/// attributes stay apart, so each reader picks the one it trusts.
public struct Record: Codable, Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var description: String?
    /// Nil on a secure text field: its value is never asked for.
    public var value: String?
    /// A value that is a number: a heading's level, a checkbox's state.
    public var number: Double?
    public var identifier: String?
    public var url: String?
    public var frame: Rect?
    public var depth: Int
    /// The index of the parent in the same read. Nil for the root.
    public var parent: Int?
    public var focused: Bool
    public var enabled: Bool

    public init(role: String, subrole: String? = nil, title: String? = nil, description: String? = nil,
                value: String? = nil, number: Double? = nil, identifier: String? = nil, url: String? = nil,
                frame: Rect? = nil, depth: Int = 0, parent: Int? = nil, focused: Bool = false,
                enabled: Bool = true) {
        (self.role, self.subrole, self.title, self.description) = (role, subrole, title, description)
        (self.value, self.number, self.identifier, self.url) = (value, number, identifier, url)
        (self.frame, self.depth, self.parent, self.focused, self.enabled) = (frame, depth, parent, focused, enabled)
    }

    public var isSecure: Bool { role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole }

    public var isEditable: Bool {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSecureTextField"].contains(role)
    }
}

public struct ReadOptions: Sendable {
    public var budget = 4000
    /// Teams' tree goes deeper than 40: 604 records at 40, 642 at 64 (10-09).
    public var depth = 64
    /// Checked between elements, so an element's two calls can overrun it by
    /// twice `callTimeout`.
    public var seconds: Double = 1
    /// How long one call may block. The system default is 6 s. It is set on
    /// every element the read touches, the one passed in included.
    public var callTimeout: Float = 0.1
    /// Outlook's message body is an AXTextArea of 395,489 characters.
    public var valueLimit = 4000

    public init(budget: Int = 4000, depth: Int = 64, seconds: Double = 1, callTimeout: Float = 0.1,
                valueLimit: Int = 4000) {
        (self.budget, self.depth, self.seconds) = (budget, depth, seconds)
        (self.callTimeout, self.valueLimit) = (callTimeout, valueLimit)
    }
}

public struct ReadResult: Codable, Sendable {
    public enum Stop: String, Codable, Sendable { case depth, budget, deadline }

    /// In tree order: a parent comes before its children.
    public var records: [Record]
    public var stopped: Stop?
    /// Accessibility calls sent to the app.
    public var calls: Int
    /// Elements left out because the app did not answer in time, or they went away.
    public var failed: Int
    public var milliseconds: Double
}

/// A lean read of the tree for screen context: two calls per element, and
/// plain records out.
public enum Read {
    /// The order matters: `fetch` reads them by position.
    static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXFocusedAttribute,
        kAXEnabledAttribute, kAXURLAttribute, kAXChildrenAttribute,
    ] as CFArray
    static let upward = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXFocusedAttribute,
        kAXEnabledAttribute, kAXURLAttribute, kAXParentAttribute,
    ] as CFArray

    public static func walk(from root: Element, options: ReadOptions = ReadOptions()) -> ReadResult {
        let started = Date()
        let deadline = started.addingTimeInterval(options.seconds)
        var records: [Record] = []
        var calls = 0, failed = 0
        var stopped: ReadResult.Stop?
        var stack: [(ref: AXUIElement, depth: Int, parent: Int?)] = [(root.ref, 0, nil)]
        while let (ref, depth, parent) = stack.popLast() {
            guard records.count < options.budget else { stopped = .budget; break }
            guard Date() < deadline else { stopped = .deadline; break }
            AXUIElementSetMessagingTimeout(ref, options.callTimeout)
            guard let (fetched, raw) = fetch(ref, names: attributes, valueLimit: options.valueLimit,
                                             calls: &calls) else {
                failed += 1
                continue
            }
            var record = fetched
            (record.depth, record.parent) = (depth, parent)
            records.append(record)
            let children = raw as? [AXUIElement] ?? []
            if depth + 1 < options.depth {
                let index = records.count - 1
                stack += children.reversed().map { ($0, depth + 1, index) }
            } else if !children.isEmpty {
                stopped = .depth
            }
        }
        return ReadResult(records: records, stopped: stopped, calls: calls, failed: failed,
                          milliseconds: Date().timeIntervalSince(started) * 1000)
    }

    /// The element and the ones above it, root first, the element last: a
    /// read of one branch, so `parent` and `depth` hold as in `walk`. At most
    /// `options.depth` elements.
    public static func climb(from element: Element,
                             options: ReadOptions = ReadOptions()) -> [(element: Element, record: Record)] {
        let deadline = Date().addingTimeInterval(options.seconds)
        var chain: [(Element, Record)] = []
        var current: AXUIElement? = element.ref
        var calls = 0
        while let ref = current, chain.count < options.depth, Date() < deadline {
            AXUIElementSetMessagingTimeout(ref, options.callTimeout)
            guard let (record, up) = fetch(ref, names: upward, valueLimit: options.valueLimit,
                                           calls: &calls) else { break }
            chain.append((Element(ref), record))
            current = up.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        return chain.reversed().enumerated().map { depth, link in
            var record = link.1
            (record.depth, record.parent) = (depth, depth == 0 ? nil : depth - 1)
            return (link.0, record)
        }
    }

    /// The elements above this one, root first, the nearest last.
    public static func ancestors(of element: Element,
                                 options: ReadOptions = ReadOptions()) -> [(element: Element, record: Record)] {
        Array(climb(from: element, options: options).dropLast())
    }

    /// The nearest AXWebArea holding the element, or the element itself. Its
    /// record has the page title and its AXURL.
    public static func webArea(around element: Element, options: ReadOptions = ReadOptions())
        -> (element: Element, record: Record)? {
        climb(from: element, options: options).last { $0.record.role == "AXWebArea" }
    }

    /// The file a document window shows, as a URL string.
    public static func document(of window: Element, options: ReadOptions = ReadOptions()) -> String? {
        AXUIElementSetMessagingTimeout(window.ref, options.callTimeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window.ref, kAXDocumentAttribute as CFString, &value) == .success,
              let value else { return nil }
        return text(value)
    }

    /// One call for `names`, and one more for the value unless the field is
    /// secure, or its subrole could not be read: the role is not known before
    /// the first call returns. No role is skipped: Outlook's buttons and
    /// groups hold their text in the value (10-09). The last name's value is
    /// returned raw.
    private static func fetch(_ ref: AXUIElement, names: CFArray, valueLimit: Int,
                              calls: inout Int) -> (Record, AnyObject?)? {
        var raw: CFArray?
        calls += 1
        guard AXUIElementCopyMultipleAttributeValues(ref, names, AXCopyMultipleAttributeOptions(), &raw) == .success,
              let values = raw as? [AnyObject], values.count == CFArrayGetCount(names),
              let role = text(values[0]) else { return nil }
        var record = Record(
            role: role, subrole: text(values[1]), title: text(values[2]), description: text(values[3]),
            identifier: text(values[4]), url: text(values[9]), frame: frame(values[5], values[6]),
            focused: (values[7] as? NSNumber)?.boolValue ?? false,
            enabled: (values[8] as? NSNumber)?.boolValue ?? true)
        if !record.isSecure, subroleIsKnown(values[1]) {
            calls += 1
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &value) == .success, let value {
                if CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFBooleanGetTypeID() {
                    record.number = (value as? NSNumber)?.doubleValue
                } else if let string = text(value) {
                    record.value = String(string.prefix(valueLimit))
                }
            }
        }
        return (record, values[10])
    }

    /// A subrole read, or one the element does not have.
    private static func subroleIsKnown(_ value: AnyObject) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else {
            return true
        }
        var error = AXError.success
        guard AXValueGetValue(value as! AXValue, .axError, &error) else { return false }
        return error == .noValue || error == .attributeUnsupported
    }

    /// A string, an attributed string or a URL, as text. Nil when blank.
    private static func text(_ value: AnyObject) -> String? {
        let string: String
        if CFGetTypeID(value) == CFStringGetTypeID() {
            string = value as! String
        } else if let attributed = value as? NSAttributedString {
            string = attributed.string
        } else if let url = value as? URL {
            string = url.absoluteString
        } else {
            return nil
        }
        return string.allSatisfy(\.isWhitespace) ? nil : string
    }

    private static func frame(_ position: AnyObject, _ size: AnyObject) -> Rect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return Rect(CGRect(origin: point, size: extent))
    }
}
