import AppKit
import ApplicationServices

/// `--edit-test <needle> <replacement> --find <sentinel>` — performs one real
/// in-place edit against the frontmost app and reports which branch took it.
///
/// `--span-test <start> <length> <replacement> --find <sentinel>` does the same
/// thing to a character range instead of to a word, which is the only way to
/// exercise the layer as the app now uses it: a caller that knows exactly which
/// characters it wants changed says so, and nothing searches for anything.
///
/// The counterpart to `--peek`, and the reason that command cannot be the whole
/// harness. A read can say whether there is a selection and whether the value
/// looks like a field, but it cannot say whether a write will land: setting a
/// range returns `.success` in surfaces that then ignore it, so the only way to
/// learn what one really does is to write to it and look.
///
/// Looking is not this command's job. It says what it attempted and what the
/// accessibility API claimed; whether the text actually changed is answered by
/// something outside this process — `tmux capture-pane` reading a pane through
/// the pty, or the fixture page reporting its own DOM — which owes nothing to
/// the API being tested.
///
/// `--find` is required, not optional. This writes into whichever window happens
/// to be frontmost, and a harness that mis-fires types into somebody's document.
/// The sentinel is the proof that the window in front is the fixture.
enum EditTestCommand {

    private static func report(_ line: String) {
        print(line)
        Log.write("edit-test: \(line)")
    }

    /// Everything both modes need before either is allowed to write.
    private static func surface(
        sentinel: String, dictated: String?, seconds: Double
    ) -> Surface? {
        // Same reason as PeekCommand: launched through LaunchServices this is an
        // ordinary app until it says otherwise, and an ordinary app wins
        // activation — then writes to its own empty focus.
        NSApplication.shared.setActivationPolicy(.accessory)

        guard Permissions.accessibility == .granted else {
            report("✗ accessibility is not granted to this binary")
            return nil
        }

        if seconds > 0 {
            print("focus the fixture window — writing in \(Int(seconds))s")
            Thread.sleep(forTimeInterval: seconds)
        }

        guard let surface = Surface.read(dictated: dictated) else {
            report("✗ nothing readable is focused")
            return nil
        }
        guard surface.content.contains(sentinel) else {
            report("✗ sentinel \"\(sentinel)\" not in the content — refusing to write")
            report("  content: \"\(surface.content.prefix(120))\"")
            return nil
        }
        report("surface   \(surface.kind), \(surface.content.count) chars"
            + (surface.span.map { _ in ", selection present" } ?? ""))
        return surface
    }

    /// `literal` selects how the needle is found, which is the only thing the
    /// two modes of this command disagree about. A transform's needle is a whole
    /// phrase, punctuation and all, which a word-boundary rule cannot match; a
    /// correction's is a word that may be spelled differently on screen.
    static func run(
        needle: String,
        replacement: String,
        sentinel: String,
        dictated: String?,
        literal: Bool,
        seconds: Double
    ) -> Int32 {
        defer { Log.flush() }
        guard let surface = surface(
            sentinel: sentinel, dictated: dictated, seconds: seconds
        ) else { return 2 }

        // The same order as `applyInPlace`, and for the same reason. A rule
        // applies to every occurrence on the line; a phrase is the one sentence
        // just dictated, and only its last occurrence is that sentence.
        var updated = surface.content
        if literal {
            if let found = updated.range(of: needle, options: [.caseInsensitive, .backwards]) {
                updated = updated.replacingCharacters(in: found, with: replacement)
            }
        } else {
            updated = SelectionReader.applying(
                [(heard: needle, corrected: replacement)], to: updated
            )
        }
        guard let change = Surface.minimalSpan(from: surface.content, to: updated) else {
            report("✗ \"\(needle)\" is not in the content — nothing to replace")
            return 2
        }

        report("replacing \"\(surface.content[change.range])\" with \"\(change.replacement)\"")
        return write(change.range, change.replacement, in: surface)
    }

    /// The span mode: a range, given rather than searched for.
    static func runSpan(
        start: Int, length: Int,
        replacement: String,
        sentinel: String,
        dictated: String?,
        seconds: Double
    ) -> Int32 {
        defer { Log.flush() }
        guard let surface = surface(
            sentinel: sentinel, dictated: dictated, seconds: seconds
        ) else { return 2 }

        guard start >= 0, length >= 0,
              let range = Range(NSRange(location: start, length: length), in: surface.content)
        else {
            report("✗ \(start)+\(length) is not a range of \(surface.content.count) chars")
            return 2
        }

        report("replacing \(start)+\(length) — \"\(surface.content[range])\" → \"\(replacement)\"")
        return write(range, replacement, in: surface)
    }

    private static func write(
        _ range: Range<String.Index>, _ replacement: String, in surface: Surface
    ) -> Int32 {
        switch surface.replace(range, with: replacement) {
        case .replaced:
            // Deliberately not "succeeded". This is what the write path claimed,
            // which is the thing under test, not the verdict on it.
            report("claimed: written")
            return 0
        case .refused(let why):
            report("claimed: refused — \(why)")
            return 3
        }
    }
}
