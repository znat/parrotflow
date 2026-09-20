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
    static func perform(
        _ decision: ActionDecider.Decision,
        in snapshot: ScreenTargets.Snapshot,
        utterance: String,
        send: Bool
    ) async -> Outcome {
        switch decision.action {
        case .none:
            return .nothing("Nothing to do on screen")

        case .scroll:
            // Which way is in the words, not in the model: it was asked what
            // kind of thing this is, and "down" is not a target.
            let down = utterance.lowercased().contains("down") || utterance.lowercased().contains("bas")
            press(down ? CGKeyCode(kVK_DownArrow) : CGKeyCode(kVK_UpArrow))
            return .did(down ? "Scrolled down" : "Scrolled up")

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
