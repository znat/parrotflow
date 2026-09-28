import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
        /// Something else is on top of the point a drag starts or ends at.
        case covered(CGPoint, String)
        /// The pointer moved while the kit held it: someone is using the mouse.
        case mouseTaken

        public var description: String {
            switch self {
            case .screenLocked: return "the screen is locked: keys would go to the password field"
            case .secureInput(let pid): return "process \(pid) holds secure input (a password field)"
            case .notFrontmost(let expected, let actual):
                return "process \(expected) is not in front (\(actual.map(String.init) ?? "nothing") is)"
            case .covered(let point, let what): return "\(what) is on top at \(Int(point.x)),\(Int(point.y))"
            case .mouseTaken: return "the pointer moved during the drag: stopped"
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

    /// Key codes are positions on the keyboard, not letters: on AZERTY the
    /// code of A is Q, and ⌘ of it would quit the app. So no letter keys
    /// here: a shortcut with a letter goes through `shortcut`, which asks the
    /// current layout where the letter is.
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

    /// ⌘V, ⌘K…: the key that types `letter` on the current layout, with the
    /// modifiers. Throws when the layout has no key for it.
    public static func shortcut(_ letter: Character, _ modifiers: Modifiers, to route: Route) throws {
        guard let code = keyCode(for: letter) else {
            throw AXKitError.ax(.illegalArgument, "no key types \"\(letter)\" on this layout")
        }
        if let refusal = refusal(for: route) { throw refusal }
        post(code: code, flags: CGEventFlags(rawValue: modifiers.rawValue), unicode: nil, route: route)
    }

    /// The key code that types `letter` on the current keyboard layout, with
    /// no modifier. On AZERTY, "a" is 12 (the Q position) and "q" is 0.
    public static func keyCode(for letter: Character) -> CGKeyCode? {
        let wanted = String(letter).lowercased()
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == wanted {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    public static func press(_ keys: [Key], to route: Route) throws {
        for key in keys { try press(key, to: route) }
    }

    /// Drags from the middle of one element to the middle of another, with
    /// the real pointer: a foreground step, for drop zones that take nothing
    /// else. Both points must show their own element on top, which usually
    /// means both apps in front and side by side. The pointer and the
    /// frontmost app are put back after. If the pointer moves under the kit's
    /// hand, the drag is dropped where it started and the call throws.
    /// `at`: where to press on the source, when its middle is not where the
    /// app starts a drag: the icon of a Finder list row, not its name.
    public static func drag(from source: Element, at grip: CGPoint? = nil, to target: Element) throws {
        guard let a = source.visibleFrame, let b = target.visibleFrame else {
            throw AXKitError.ax(.failure, "an element has no frame")
        }
        let start = grip ?? CGPoint(x: a.midX, y: a.midY), end = CGPoint(x: b.midX, y: b.midY)
        for (point, element) in [(start, source), (end, target)] {
            // The same window, not only the same app: another Finder window
            // can sit on top of the one the file is in.
            let top = App.element(at: point)
            guard let top, top.pid == element.pid, top.window == element.window else {
                let owner = top?.pid.flatMap { App(pid: $0).name } ?? "nothing"
                let window = top?.window?.title.map { " window \"\($0)\"" } ?? ""
                throw Refusal.covered(point, "\(owner)\(window) (\(top?.role ?? "?"))")
            }
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { throw Refusal.screenLocked }

        let home = CGEvent(source: nil)?.location ?? start
        let front = NSWorkspace.shared.frontmostApplication
        defer {
            mouse(.mouseMoved, home)
            if let front { App(pid: front.processIdentifier).activate() }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        // During a drag the reported pointer lags a few events behind the
        // kit's (measured 09-28): only a pointer far from the recent path
        // means a hand on the mouse.
        var recent: [CGPoint] = []
        func at(_ point: CGPoint) -> Bool {
            guard let now = CGEvent(source: nil)?.location else { return true }
            return (recent + [point]).contains { abs(now.x - $0.x) < 60 && abs(now.y - $0.y) < 60 }
        }
        mouse(.mouseMoved, start, source)
        usleep(100_000)
        mouse(.leftMouseDown, start, source)
        usleep(150_000)
        // An app starts a drag only after the pointer has moved a few points.
        var last = start
        let steps = 30
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            guard at(last) else {
                mouse(.leftMouseUp, start, source)
                throw Refusal.mouseTaken
            }
            mouse(.leftMouseDragged, point, source)
            recent = Array((recent + [last]).suffix(6))
            last = point
            usleep(15_000)
        }
        // Drop targets highlight and accept only after a short hover.
        usleep(300_000)
        mouse(.leftMouseDragged, end, source)
        usleep(100_000)
        mouse(.leftMouseUp, end, source)
        usleep(200_000)
    }

    /// A drag the Finder takes carries a click count of 1 on the press, the
    /// moves and the release, and each move's offset from the last.
    private static var lastPoint: CGPoint?

    private static func mouse(_ type: CGEventType, _ point: CGPoint, _ source: CGEventSource? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        if type == .leftMouseDragged, let last = lastPoint {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - last.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - last.y).rounded()))
        }
        lastPoint = point
        event.post(tap: .cghidEventTap)
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
