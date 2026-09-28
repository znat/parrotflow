import AppKit
import ApplicationServices

/// Synthetic keys. Every call checks first that keys cannot land somewhere
/// unintended: a locked screen sends them to the password field, and a
/// frontmost-routed key goes to whatever app is in front.
public enum Input {
    public enum Route: Equatable, Sendable {
        /// The keys go to the frontmost app, which must be this pid.
        case frontmost(pid_t)
        /// The keys go to this pid only, even with another app in front.
        /// Worked in Chrome, Teams and AppKit; in Outlook only once the
        /// field's window is made main (see `prepare`).
        case process(pid_t)

        var pid: pid_t {
            switch self { case .frontmost(let pid), .process(let pid): return pid }
        }
    }

    public enum Refusal: Error, CustomStringConvertible, Equatable {
        case screenLocked
        case secureInput(pid_t)
        case notFrontmost(expected: pid_t, actual: pid_t?)

        public var description: String {
            switch self {
            case .screenLocked: return "the screen is locked: keys would go to the password field"
            case .secureInput(let pid): return "process \(pid) holds secure input (a password field)"
            case .notFrontmost(let expected, let actual):
                return "process \(expected) is not in front (\(actual.map(String.init) ?? "nothing") is)"
            }
        }
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: CGEventFlags.maskCommand.rawValue)
        public static let option = Modifiers(rawValue: CGEventFlags.maskAlternate.rawValue)
        public static let control = Modifiers(rawValue: CGEventFlags.maskControl.rawValue)
        public static let shift = Modifiers(rawValue: CGEventFlags.maskShift.rawValue)
    }

    /// Key codes are positions on the keyboard, not letters, so there are no
    /// letter keys here: on AZERTY the code of A is Q, and ⌘ of it would quit
    /// the app. Text goes through `type`; select-all through `selectAll`.
    public enum Key: String, CaseIterable, Sendable {
        case `return`, tab, space, escape, delete, forwardDelete
        case left, right, up, down, home, end, pageUp, pageDown

        var code: CGKeyCode {
            switch self {
            case .return: return 36
            case .tab: return 48
            case .space: return 49
            case .escape: return 53
            case .delete: return 51
            case .forwardDelete: return 117
            case .left: return 123
            case .right: return 124
            case .down: return 125
            case .up: return 126
            case .home: return 115
            case .end: return 119
            case .pageUp: return 116
            case .pageDown: return 121
            }
        }
    }

    /// Why keys may not be sent now, or nil.
    public static func refusal(for route: Route) -> Refusal? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return .screenLocked }
        if let holder = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, holder != 0,
           holder != route.pid {
            return .secureInput(holder)
        }
        if case .frontmost(let pid) = route {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front != pid { return .notFrontmost(expected: pid, actual: front) }
        }
        return nil
    }

    /// Makes the element's window main and focuses the element, without
    /// bringing the app in front. Returns whether the focus is there.
    @discardableResult
    public static func prepare(_ element: Element) -> Bool {
        if let window = element.window {
            try? window.set(kAXMainAttribute, to: kCFBooleanTrue)
        }
        try? element.set(kAXFocusedAttribute, to: kCFBooleanTrue)
        return Controls.wait { element.isFocused == true }
    }

    /// Selects everything a text field holds, through accessibility, so
    /// the next `type` replaces it. No shortcut involved.
    public static func selectAll(_ element: Element) throws {
        let length = (element.valueText ?? "").utf16.count
        var range = CFRange(location: 0, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        try element.set(kAXSelectedTextRangeAttribute, to: value)
    }

    /// Text as unicode characters, so the keyboard layout does not matter.
    /// A newline is Return.
    public static func type(_ text: String, to route: Route) throws {
        for character in text {
            if let refusal = refusal(for: route) { throw refusal }
            if character == "\n" {
                post(code: Key.return.code, flags: [], unicode: nil, route: route)
            } else {
                post(code: 0, flags: [], unicode: Array(String(character).utf16), route: route)
            }
        }
    }

    public static func press(_ key: Key, _ modifiers: Modifiers = [], to route: Route) throws {
        if let refusal = refusal(for: route) { throw refusal }
        post(code: key.code, flags: CGEventFlags(rawValue: modifiers.rawValue), unicode: nil, route: route)
    }

    public static func press(_ keys: [Key], to route: Route) throws {
        for key in keys { try press(key, to: route) }
    }

    /// Measured: 15 ms between events keeps up with Teams and Outlook.
    static let gap: useconds_t = 15_000

    private static func post(code: CGKeyCode, flags: CGEventFlags, unicode: [UniChar]?, route: Route) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            if let unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            switch route {
            case .process(let pid): event.postToPid(pid)
            case .frontmost: event.post(tap: .cghidEventTap)
            }
            usleep(gap)
        }
    }
}
