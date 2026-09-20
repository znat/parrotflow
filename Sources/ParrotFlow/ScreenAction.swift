import AppKit
import Carbon.HIToolbox

/// Carries out one decision: the click, the typing, the keys.
///
/// A port of the prototype's `tools/axdo.swift` and the branch table at the
/// bottom of `tools/act.py`. Nothing here decides anything — what to do and
/// what to do it to arrived in the `Decision`, and every branch below is a
/// sequence of events with waits between them.
///
/// The waits are the substance. A click on a conversation does not put the
/// composer on screen by the time the call returns, and typing into a field
/// that is not there yet types into whatever was. They are the prototype's,
/// unmeasured, and the first thing to look at when a step lands in the wrong
/// place.
enum ScreenAction {

    /// What happened, for the pill and the log. Every case is a sentence
    /// somebody reads after an action did not do what they expected.
    enum Outcome {
        case did(String)
        case nothing(String)

        var isAction: Bool { if case .did = self { return true }; return false }
        var said: String {
            switch self {
            case .did(let what), .nothing(let what): return what
            }
        }
    }

    /// Runs a decision against the screen.
    ///
    /// `snapshot` is what was decided over — used again for the composer,
    /// which is not the thing clicked. `send` gates Return and nothing else:
    /// with it off the words land in the field and stay there.
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

    static func perform(
        _ decision: ActionDecider.Decision,
        in snapshot: ScreenTargets.Snapshot,
        utterance: String,
        send: Bool,
        never: [String] = [],
        at gaze: CGPoint? = nil
    ) async -> Outcome {
        // Before anything is posted. A target whose name is on the list is
        // not pressed, not by this step and not by a later one.
        if let target = decision.target, let word = refuses(target.name, never) {
            Log.write("action: refused — \"\(target.name.prefix(40))\" matches \"\(word)\"")
            return .nothing("Won't press \"\(target.name.prefix(30))\" — that is yours to do")
        }
        switch decision.action {
        case .none:
            return .nothing("Nothing to do on screen")

        case .scroll:
            // Which way is in the words, not in the model: it was asked what
            // kind of thing this is, and "down" is not a target.
            let words = utterance.lowercased()
            let down = words.contains("down") || words.contains("bas")
                || words.contains("descend")

            // *Where* is the gaze, and this is the one step where that
            // matters most. An arrow key scrolls whatever holds the keyboard
            // focus, which is the conversation — so "scroll up the sidebar"
            // scrolled the conversation instead. A wheel event carries a
            // location, and the pane under that point is the one that moves.
            let point = decision.target?.point ?? gaze
            guard let point else {
                press(down ? CGKeyCode(kVK_DownArrow) : CGKeyCode(kVK_UpArrow))
                return .did(down ? "Scrolled down" : "Scrolled up")
            }
            wheel(at: point, down: down)
            return .did(down ? "Scrolled down where you were looking"
                             : "Scrolled up where you were looking")

        case .newMessage:
            // ⌘N, the same shape as `search` below: the thing that opens the
            // picker is a shortcut, not a target, and a target that is not on
            // screen can never be offered. What comes next is a second step,
            // over the window the picker draws.
            press(CGKeyCode(kVK_ANSI_N), flags: .maskCommand)
            return .did("Opened a new message — say who it is to")

        case .search:
            // Slack's search bar is not a text field as far as the
            // accessibility API is concerned, so it is never among the
            // targets and the model cannot pick what it was not offered —
            // measured: it chose the composer at 0.80. ⌘G is Slack's own
            // shortcut for it. Slack-shaped, and wrong in another app.
            press(CGKeyCode(kVK_ANSI_G), flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let text = decision.text else { return .did("Opened search") }
            type(text)
            if send { press(CGKeyCode(kVK_Return)) }
            return .did("Searched for \(text)")

        case .click, .type, .sendMessage:
            guard let target = decision.target else {
                return .nothing("Nothing here matches \"\(utterance)\"")
            }
            activate(target)
            let name = target.name.isEmpty ? target.role : String(target.name.prefix(40))
            if decision.action == .click { return .did("Clicked \(name)") }

            try? await Task.sleep(nanoseconds: 500_000_000)

            // A message goes in the composer, and the thing clicked was the
            // conversation. Find it again after the click: the window has
            // changed, and the row the gaze was on has moved.
            if decision.action == .sendMessage, target.kind != ScreenTargets.Kind.text {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let composer = composer(ofApp: snapshot.app) else {
                    return .nothing("Opened \(name), but found no message box")
                }
                activate(composer)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            guard let text = decision.text else {
                return .did("Opened \(name) — dictate the message")
            }
            type(text)
            guard send else { return .did("Typed into \(name), not sent") }
            press(CGKeyCode(kVK_Return))
            return .did("Sent to \(name)")
        }
    }

    /// The message box of an app's front window: a text field in the bottom
    /// fifth of it. It has no name in Slack, so where it is is all there is.
    private static func composer(ofApp app: String) -> ScreenTargets.Item? {
        guard let now = try? ScreenTargets.snapshot(ofApp: app, at: .zero) else { return nil }
        return now.items.first {
            $0.kind == ScreenTargets.Kind.text && now.relativeY(of: $0) > 0.8
        }
    }

    // MARK: - Events

    /// Activates a target: by asking it, if it says it can be pressed, and by
    /// clicking it if not.
    ///
    /// Asking is strictly better where it works. A click has to put the
    /// pointer on the target, and moving the pointer closes anything drawn
    /// because of where the pointer was — which is how the first real use of
    /// this ended, with the menu holding the target collapsing and nothing
    /// else happening.
    ///
    /// A text field is clicked rather than pressed: pressing one does not put
    /// the caret in it, and the caret is the whole reason for touching it.
    static func activate(_ target: ScreenTargets.Item) {
        let point = target.point
        let canPress = target.actions.contains(kAXPressAction)
            && target.kind != ScreenTargets.Kind.text
        if canPress, ScreenTargets.press(at: point) {
            Log.write("action: pressed at \(Int(point.x)),\(Int(point.y)) — the pointer did not move")
            return
        }
        Log.write("action: clicking at \(Int(point.x)),\(Int(point.y))"
            + (canPress ? " — the press was refused" : ""))
        click(at: point)
    }

    /// Moves the pointer there first, because an app that tracks hover draws
    /// the thing being clicked before the click lands. The waits are
    /// `axdo`'s.
    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        post(CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        ))
        usleep(80_000)
        post(CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ))
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
        let wasAt = Gaze.mouse()
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

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        post(down)
        post(up)
    }

    private static func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
