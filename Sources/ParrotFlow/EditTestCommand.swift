import AppKit
import ApplicationServices

/// `--edit-test <needle> <replacement> --find <sentinel>` — performs one real
/// in-place edit against the frontmost app and reports which branch took it.
///
/// The counterpart to `--peek`, and the reason that command cannot be the whole
/// harness. A read can say whether there is a selection and whether the value
/// looks like a field, but it cannot say whether a write will land: setting a
/// range returns `.success` in terminals that then ignore it, so the only way
/// to learn what a surface really does is to write to it and look.
///
/// Looking is not this command's job. It says what it attempted and what the
/// accessibility API claimed; whether the text actually changed is answered by
/// something outside this process — `tmux capture-pane` reading the pane
/// through the pty, which owes nothing to the API being tested.
///
/// `--find` is required, not optional. This synthesises keystrokes into
/// whichever window happens to be frontmost, and a harness that mis-fires types
/// into somebody's document. The sentinel is the proof that the window in front
/// is the fixture and not a real one.
enum EditTestCommand {

    private static func report(_ line: String) {
        print(line)
        Log.write("edit-test: \(line)")
    }

    /// `dictated` selects the route. Absent, this exercises the accessibility
    /// write — the one a terminal refuses. Present, it exercises the keystroke
    /// retype, which needs to be told what it put on the line because that is
    /// the whole point of it: nothing is read back off the screen.
    static func run(
        needle: String,
        replacement: String,
        sentinel: String,
        dictated: String?,
        literal: Bool,
        seconds: Double
    ) -> Int32 {
        defer { Log.flush() }

        // Same reason as PeekCommand: launched through LaunchServices this is an
        // ordinary app until it says otherwise, and an ordinary app wins
        // activation — then writes to its own empty focus.
        NSApplication.shared.setActivationPolicy(.accessory)

        guard Permissions.accessibility == .granted else {
            report("✗ accessibility is not granted to this binary")
            return 1
        }

        if seconds > 0 {
            print("focus the fixture window — writing in \(Int(seconds))s")
            Thread.sleep(forTimeInterval: seconds)
        }

        guard let element = SelectionReader.focusedElement() else {
            report("✗ nothing focused")
            return 2
        }
        guard !SelectionReader.isOurs(element) else {
            report("✗ focused element is ParrotFlow's own")
            return 2
        }
        guard let value = SelectionReader.visibleText(of: element) else {
            report("✗ focused element has no readable value")
            return 2
        }
        guard value.contains(sentinel) else {
            report("✗ sentinel \"\(sentinel)\" not in the focused element — refusing to write")
            return 2
        }
        guard value.contains(needle) else {
            report("✗ \"\(needle)\" is not on screen — nothing to replace")
            return 2
        }

        let landed: Bool
        if let dictated, literal {
            // The route a transform takes: a whole phrase, punctuation and all,
            // which a word-boundary rule cannot match.
            report("retyping the line literally, \"\(needle)\" → \"\(replacement)\"")
            landed = SelectionReader.rewriteCurrentLine(dictated: dictated, in: element) { line in
                guard let found = line.range(
                    of: needle, options: [.caseInsensitive, .backwards]
                ) else { return line }
                return line.replacingCharacters(in: found, with: replacement)
            }
        } else if let dictated {
            report("retyping the line, \"\(needle)\" → \"\(replacement)\"")
            landed = SelectionReader.rewriteCurrentLine(
                applying: [(heard: needle, corrected: replacement)],
                dictated: dictated,
                in: element
            )
        } else {
            report("writing \"\(needle)\" → \"\(replacement)\"")
            landed = SelectionReader.replaceLastOccurrence(
                of: needle, with: replacement, in: element
            )
        }
        // Deliberately not "succeeded". This is what the accessibility API said,
        // which is the claim under test, not the verdict on it.
        report(landed ? "claimed: written" : "claimed: refused")
        return landed ? 0 : 3
    }
}
