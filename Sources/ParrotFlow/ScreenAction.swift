import AppKit
import Carbon.HIToolbox

/// The events a step posts: the click, the typing, the keys. Nothing here
/// decides anything; the runner does (`built-in/recipes/loop.py`).
///
/// The waits are the prototype's (`tools/axdo.swift`), unmeasured, and the
/// first thing to look at when a step lands in the wrong place.
enum ScreenAction {

    /// Names this will not press, whatever was decided.
    ///
    /// A word-boundary match on the target's name, so "Send" and "Send now"
    /// are refused and "Sender" is not. The check is here, at the last
    /// moment before the event is posted, because that is the only place
    /// nothing can get past it: not in the prompt, where it is a request, and
    /// not at the decision, which the loop may revisit.
    static func refuses(_ name: String, _ never: [String]) -> String? {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        return never.first { forbidden in
            let phrase = forbidden.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return !phrase.isEmpty && text.contains(" " + phrase + " ")
        }
    }

    // MARK: - Events

    /// Presses a target through accessibility, if it says it can be pressed.
    /// When it cannot, the caller clicks it.
    ///
    /// Asking is strictly better where it works. A click has to put the
    /// pointer on the target, and moving the pointer closes anything drawn
    /// because of where the pointer was — which is how the first real use of
    /// this ended, with the menu holding the target collapsing and nothing
    /// else happening.
    ///
    /// A text field is clicked rather than pressed: pressing one does not put
    /// the caret in it, and the caret is the whole reason for touching it.
    /// Says whether it was pressed. False means nothing happened yet and the
    /// caller clicks, after checking what is under the point.
    static func pressWithoutPointer(_ target: ScreenTargets.Item, clickRatherThanPress: Bool = false) -> Bool {
        let point = target.point
        // A row in a list that a lookup field is filtering takes a real
        // click and nothing else. Measured: pressing Peter's row through the
        // accessibility API reported success, closed the list, and selected
        // nobody — the same way a press closed a menu earlier without
        // opening anything. A press is not a click, and some things only
        // accept the real one.
        let canPress = !clickRatherThanPress
            && !target.isChoiceInAList
            && target.actions.contains(kAXPressAction)
            && target.kind != ScreenTargets.Kind.text
        guard canPress else { return false }
        let error = ScreenTargets.press(at: point)
        if error == .success {
            Log.write("action: pressed at \(Int(point.x)),\(Int(point.y)) — the pointer did not move")
            return true
        }
        // Seen 09-24: Outlook's "New Event" answered cannotComplete and opened
        // the form anyway, so the click that followed opened a second one.
        // The caller's read of the tree decides whether it worked.
        if error == .cannotComplete {
            Log.write("action: the press at \(Int(point.x)),\(Int(point.y)) timed out — not confirmed, no click")
            return true
        }
        Log.write("action: the press was refused at \(Int(point.x)),\(Int(point.y)) — AXError \(error.rawValue)")
        return false
    }

    /// Presses at one point and releases at another, in steps. A drag that
    /// starts outside a block and ends outside it selects the whole block in
    /// Notion — Nathan's way of deleting a table, which has no keyboard route
    /// and no menu the accessibility API will open.
    static func drag(from: CGPoint, to: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGWarpMouseCursorPosition(from)
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                     mouseCursorPosition: from, mouseButton: .left))
        usleep(80_000)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                     mouseCursorPosition: from, mouseButton: .left))
        for step in 1...12 {
            let at = CGPoint(x: from.x + (to.x - from.x) * Double(step) / 12,
                             y: from.y + (to.y - from.y) * Double(step) / 12)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                         mouseCursorPosition: at, mouseButton: .left))
            usleep(25_000)
        }
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                     mouseCursorPosition: to, mouseButton: .left))
    }

    /// Puts the pointer somewhere with a real move, so that whatever the app
    /// draws on hover gets drawn. A warp alone is not a move, and an app that
    /// waits for the pointer to arrive never sees it arrive.
    static func hover(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let from = CGPoint(x: point.x + 40, y: point.y)
        CGWarpMouseCursorPosition(from)
        for step in 1...5 {
            let at = CGPoint(x: from.x + (point.x - from.x) * Double(step) / 5, y: point.y)
            post(CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: at, mouseButton: .left
            ))
            usleep(30_000)
        }
    }

    /// The secondary click, for a context menu the accessibility action would
    /// not open. Same shape as `click(at:)` — warp, move, down, up — with the
    /// right button and the control flag off.
    static func rightClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGWarpMouseCursorPosition(point)
        post(CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .right
        ))
        usleep(80_000)
        post(CGEvent(
            mouseEventSource: source, mouseType: .rightMouseDown,
            mouseCursorPosition: point, mouseButton: .right
        ))
        usleep(40_000)
        post(CGEvent(
            mouseEventSource: source, mouseType: .rightMouseUp,
            mouseCursorPosition: point, mouseButton: .right
        ))
    }

    /// Drags across the target, which is what selecting text is.
    ///
    /// A click puts the caret somewhere and selects nothing — measured on
    /// "select and create a comment on Q&A content", which found the right
    /// words, clicked them, and changed nothing. The drag runs from just
    /// inside the left edge to just inside the right, along the middle, so
    /// what ends up highlighted is that element's own text and no more.
    static func selectText(of target: ScreenTargets.Item) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let y = Double(target.y)
        let from = CGPoint(x: Double(target.x - target.w / 2) + 2, y: y)
        let to = CGPoint(x: Double(target.x + target.w / 2) - 2, y: y)
        Log.write(
            "action: selecting from \(Int(from.x)),\(Int(from.y)) to \(Int(to.x)),\(Int(to.y))"
        )
        CGWarpMouseCursorPosition(from)
        post(CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: from, mouseButton: .left
        ))
        usleep(80_000)
        post(CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: from, mouseButton: .left
        ))
        // In steps, because an app that tracks the drag needs to see it move.
        // One jump from end to end is read as a click by some of them.
        for step in 1...6 {
            let at = CGPoint(x: from.x + (to.x - from.x) * Double(step) / 6, y: y)
            post(CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDragged,
                mouseCursorPosition: at, mouseButton: .left
            ))
            usleep(20_000)
        }
        post(CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: to, mouseButton: .left
        ))
    }

    /// Moves the pointer there first, because an app that tracks hover draws
    /// the thing being clicked before the click lands. The waits are
    /// `axdo`'s.
    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // The pointer has to actually be there for a click to land where a
        // hover-driven list expects it, so it is warped first and the move
        // is posted from there.
        CGWarpMouseCursorPosition(point)
        post(CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        ))
        usleep(80_000)
        post(CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ))
        // Outlook's suggestion rows ignored a down and up posted together.
        usleep(50_000)
        post(CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ))
    }

    /// Turns the wheel over a point, without moving the pointer there.
    ///
    /// A scroll event carries its own location, so the pane under that point
    /// is the one that moves — which is how "the sidebar" and "the
    /// conversation" are told apart at all. Several small turns rather than
    /// one large one: a single big delta is dropped or clamped by some
    /// scrollers, and small ones read as a flick.
    static func wheel(at point: CGPoint, down: Bool, turns: Int = 6) {
        // The pointer has to be there. A scroll event carries a location and
        // Slack ignores it — measured: six turns aimed at the sidebar moved
        // nothing at all, in either pane. Chromium routes a wheel by where
        // the cursor actually is, so the cursor goes there.
        //
        // Warped rather than moved: `CGWarpMouseCursorPosition` sets the
        // position without posting a move, so nothing reads it as the mouse
        // travelling across the window. It is put back afterwards, because
        // the pointer is the user's and a scroll should not steal it.
        let wasAt = CGEvent(source: nil)?.location ?? point
        CGWarpMouseCursorPosition(point)
        usleep(50_000)
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<turns {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                wheel1: down ? -3 : 3, wheel2: 0, wheel3: 0
            ) else { break }
            event.location = point
            event.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        usleep(50_000)
        CGWarpMouseCursorPosition(wasAt)
    }

    /// Pastes rather than pressing a key per character.
    ///
    /// `axdo` typed each character as its own event. ParrotFlow already has a
    /// paste that is atomic from the target app's point of view, keeps
    /// non-ASCII intact, and puts the clipboard back afterwards — which is
    /// every reason `TextInserter` exists, and they all apply here.
    static func type(_ text: String) {
        TextInserter.insert(text)
    }

    /// Types a few characters as real keystrokes, one at a time.
    ///
    /// A paste is the right way to put a sentence somewhere, and the wrong
    /// way to fill a field that filters a list. Measured in Slack's recipient
    /// field: pasting "Pe" made it a token reading "1 entry has multiple
    /// matches. Select entry to resolve." — the field took the paste as a
    /// value being committed rather than as somebody typing. Keystrokes
    /// filter the list, which is what the next step needs to see.
    ///
    /// For a name fragment only. Anything longer goes through the paste,
    /// which is atomic, keeps non-ASCII intact, and puts the clipboard back.
    static func keystrokes(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            // The real key for the letter, not the A key wearing it.
            //
            // Measured in Slack: into an empty recipient field, a letter sent
            // as virtual key 0 with the character attached arrived every
            // time. Into a field already holding a name, the same events
            // deleted the name or vanished — while Nathan, typing by hand into
            // exactly that state, got a list. The field reads which key was
            // pressed as well as what it typed, and key 0 is not an "n".
            //
            // The character stays attached too, so a key missing from the
            // table below, or a keyboard that is not US, still types right.
            let key = keyCodes[Character(character.lowercased())] ?? 0
            let shifted = character.isUppercase
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { return }
            var units = Array(String(character).utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            // Set every time: left alone, the flags follow the keyboard's
            // current state. Seen 09-23: typing "4:00 PM" into Teams switched
            // it to Calls, which is ⌘4.
            down.flags = shifted ? .maskShift : []
            up.flags = shifted ? .maskShift : []
            down.post(tap: .cghidEventTap)
            usleep(25_000)
            up.post(tap: .cghidEventTap)
            usleep(45_000)
        }
    }

    /// US-layout key codes for the characters a name is typed with.
    private static let keyCodes: [Character: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9), " ": CGKeyCode(kVK_Space), "-": CGKeyCode(kVK_ANSI_Minus),
        ".": CGKeyCode(kVK_ANSI_Period),
    ]

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        post(down)
        post(up)
    }

    /// One key, `times` times, 2 ms between events. Measured 09-25: 73 right
    /// arrows at that pace landed on the right character in TextEdit and in
    /// Chrome.
    static func repeatKey(_ key: CGKeyCode, flags: CGEventFlags = [], times: Int) {
        guard times > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<times {
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            down?.flags = flags
            up?.flags = flags
            post(down, wait: 2_000)
            post(up, wait: 2_000)
        }
        usleep(100_000)
    }

    /// On every key this app presses, so Escape's watch can tell a planned
    /// Escape from yours: a planned one stopped the run it was part of.
    static let mark: Int64 = 0x5046_4b59

    private static func post(_ event: CGEvent?, wait: useconds_t = 30_000) {
        event?.setIntegerValueField(.eventSourceUserData, value: mark)
        event?.post(tap: .cghidEventTap)
        usleep(wait)
    }
}
