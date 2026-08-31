import AppKit
import ApplicationServices

/// Notices when you change one word of what ParrotFlow just wrote.
///
/// That change is the most useful thing this app can learn and the only one it
/// never sees. A vocabulary term is written or missed, and the person fixes it
/// in the field — and the fix, which says exactly what the right answer was in
/// this sentence, is thrown away.
///
/// ## Why events and not a timer
///
/// Same reason as `SelectionWatch`: text cannot change on its own. Every edit
/// is a keystroke or a paste, so the question is asked at the moments the
/// answer can have changed and never in between. An idle app watches nothing.
///
/// ## What it refuses
///
/// One span, and the rest of the sentence unchanged. Two edits, a rewrite, or
/// clearing the line are not corrections of a word — they are somebody writing
/// something else, and reading them as a lesson would teach nonsense. The rule
/// is deliberately strict here, because the alternative is a portrait poisoned
/// by its own noise.
///
/// It also fires once. The same span keeps being read as long as the field is
/// open, and a correction told twice is not two corrections.
final class EditWatch {

    /// One word of the dictation became another.
    struct Change: Equatable {
        /// What ParrotFlow wrote there.
        let was: String
        /// What is there now.
        let now: String
        /// The whole line as it stands, which is the sentence the change
        /// belongs to.
        let sentence: String
    }

    var onChange: ((Change) -> Void)?

    /// The whole field as it stood when the dictation landed. Both sides of the
    /// comparison are field snapshots, so neither has to be located in the
    /// other.
    private var before: String?
    private var field: AXUIElement?
    private var monitors: [Any] = []
    private var reported: Set<String> = []
    private var lastLook = Date.distantPast
    /// The read waiting for you to stop typing. Cancelled and replaced by every
    /// key, so it only ever runs once the field has been still.
    private var settling: DispatchWorkItem?

    /// How long the field has to be still before it is read.
    ///
    /// Reading on every key catches the edit half-typed: correcting `Versailles`
    /// to `Vercel` reported `Verce` first, which is not a word anybody meant.
    /// Long enough to type a name through, short enough to land before the next
    /// sentence is dictated.
    private static let quiet: TimeInterval = 1.2

    var isRunning: Bool { !monitors.isEmpty }

    /// Watch the field the dictation just landed in.
    ///
    /// `snapshot` is the whole field as it stands now, not the dictation alone.
    /// Called again for every dictation: an older snapshot is not something
    /// anybody is still editing.
    func start(field snapshot: String, in element: AXUIElement?) {
        before = snapshot
        field = element
        reported = []
        guard monitors.isEmpty else { return }
        guard Permissions.accessibility == .granted else {
            Log.write("edit watch: accessibility is not granted; corrections cannot be seen")
            return
        }

        // Key up, so the character is in the field by the time it is read. A
        // paste arrives as ⌘V, which is a key event too.
        let mask: NSEvent.EventTypeMask = [.keyUp]
        let look: (NSEvent) -> Void = { [weak self] _ in self?.look() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: look) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            look(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        settling?.cancel()
        settling = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        before = nil
        field = nil
        reported = []
    }

    deinit { stop() }

    /// A key went by. Read once the typing stops, not now.
    private func look() {
        settling?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read() }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiet, execute: work)
    }

    private func read() {
        guard let before, let field else { return }
        guard Date().timeIntervalSince(lastLook) > 0.15 else { return }
        lastLook = Date()

        guard let now = CaretAnchor.snapshot(of: field) else { return }
        guard let change = Self.change(from: before, to: now) else {
            // Said out loud while this is new. A field that changed and was not
            // read as a correction is either a rewrite — right to refuse — or a
            // correction the rule is too strict for, and the two are told apart
            // by looking at them.
            if let raw = Self.span(from: before, to: now), raw.was.count + raw.now.count < 120,
               reported.insert("skip\u{1}" + raw.was + "\u{1}" + raw.now).inserted {
                Log.write("edit watch: refused \"\(raw.was)\" -> \"\(raw.now)\"")
            }
            return
        }
        guard reported.insert(change.was + "\u{1}" + change.now).inserted else { return }
        Log.write("edit watch: \"\(change.was)\" became \"\(change.now)\"")
        onChange?(change)
    }

    // MARK: - the comparison

    /// The changed span with no rule applied, for saying what was refused.
    static func span(from before: String, to now: String) -> (was: String, now: String)? {
        guard before != now, !before.isEmpty, !now.isEmpty else { return nil }
        let old = Array(before), new = Array(now)
        var front = 0
        while front < old.count, front < new.count, old[front] == new[front] { front += 1 }
        var back = 0
        while back < old.count - front, back < new.count - front,
              old[old.count - 1 - back] == new[new.count - 1 - back] { back += 1 }
        while front > 0, !old[front - 1].isWhitespace { front -= 1 }
        while back > 0, back < old.count - front, back < new.count - front,
              !old[old.count - back].isWhitespace { back -= 1 }
        return (String(old[front ..< (old.count - back)]), String(new[front ..< (new.count - back)]))
    }

    /// The one span that differs, or nil if it is not one span.
    ///
    /// Both sides are the whole field: what it held when the dictation landed,
    /// and what it holds now. Comparing the dictation against the field instead
    /// meant hunting for where the words sat, and every anchor for that hunt is
    /// a word the edit may have been. Two snapshots of the same field need no
    /// anchor at all — what they share at the front and at the back is
    /// untouched, and what is left in the middle is the edit.
    static func change(from before: String, to now: String) -> Change? {
        guard before != now, !before.isEmpty, !now.isEmpty else { return nil }

        let old = Array(before)
        let new = Array(now)
        var front = 0
        while front < old.count, front < new.count, old[front] == new[front] { front += 1 }
        var back = 0
        while back < old.count - front, back < new.count - front,
              old[old.count - 1 - back] == new[new.count - 1 - back] { back += 1 }

        // Snap to whole words. "the Vercel Castle" against "the Versailles
        // Castle" shares "the Ver" at the front and "el Castle" at the back, so
        // the raw span is "cel" becoming "sailles" — true, and useless. A
        // correction is a word for a word.
        while front > 0, !old[front - 1].isWhitespace { front -= 1 }
        while back > 0, back < old.count - front, back < new.count - front,
              !old[old.count - back].isWhitespace { back -= 1 }

        let was = String(old[front ..< (old.count - back)])
        let became = String(new[front ..< (new.count - back)])

        // Both sides, or it is not a correction. An empty left side is text
        // typed after the dictation; an empty right side is a word deleted, and
        // a deletion says where a term does not belong without saying what
        // belongs there instead — nothing a portrait can be built from.
        guard !was.isEmpty, !became.isEmpty else { return nil }

        // One word each side, give or take. A longer span is a rewrite, and a
        // rewrite is not a correction of a name.
        guard was.count <= 24, became.count <= 24 else { return nil }
        guard was.split(separator: " ").count <= 2 else { return nil }
        guard became.split(separator: " ").count <= 2 else { return nil }

        return Change(was: was, now: became, sentence: lineAround(front, in: new))
    }

    /// The line the change sits on.
    ///
    /// The field is not always one sentence. In a terminal it is the whole
    /// buffer — 2443 characters on the first real correction, most of it
    /// somebody else's output — and a portrait built out of that would describe
    /// the screen rather than the term.
    private static func lineAround(_ index: Int, in text: [Character]) -> String {
        var start = min(index, text.count)
        while start > 0, !text[start - 1].isNewline { start -= 1 }
        var end = min(index, text.count)
        while end < text.count, !text[end].isNewline { end += 1 }
        return String(text[start ..< end]).trimmingCharacters(in: .whitespaces)
    }
}
