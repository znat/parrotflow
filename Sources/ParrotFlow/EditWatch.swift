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
    /// The one line of the field the dictation landed on, as it stood then.
    ///
    /// Not the whole field. In a terminal the field is the buffer, and the
    /// buffer changes for reasons that have nothing to do with anybody typing:
    /// the first real read compared a status line against a keyboard hint and
    /// refused them both, while the correction two lines away went unseen.
    private var before: String?
    /// What was dictated, so the line it went on can be found again while the
    /// field is still catching up.
    private var dictated: String?
    private var field: AXUIElement?
    private var monitors: [Any] = []
    private var reported: Set<String> = []
    private var lastLook = Date.distantPast
    /// The read waiting for you to stop typing. Cancelled and replaced by every
    /// key, so it only ever runs once the field has been still.
    private var settling: DispatchWorkItem?
    /// Keys seen since the watch started, so "nobody typed" can be told from
    /// "the read never ran".
    private var keysSeen = 0

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
    func start(dictated words: String, in element: AXUIElement?) {
        before = nil
        dictated = words
        field = element
        reported = []
        keysSeen = 0
        guard monitors.isEmpty else { return }
        guard Permissions.accessibility == .granted else {
            Log.write("edit watch: accessibility is not granted; corrections cannot be seen")
            return
        }

        // Key up, so the character is in the field by the time it is read. A
        // paste arrives as ⌘V, which is a key event too.
        let mask: NSEvent.EventTypeMask = [.keyUp]
        let look: (NSEvent) -> Void = { [weak self] event in self?.look(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: look) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            look(event)
            return event
        }) {
            monitors.append(local)
        }
        Log.write("edit watch: \(monitors.count) key monitor(s) installed")
        findLine(attempt: 0)
    }

    /// The line the words landed on, once they are actually there.
    ///
    /// In a terminal ParrotFlow types rather than writes, so the field is a
    /// keystroke or two behind when the dictation is declared finished. Looking
    /// once found nothing and gave up; the words arrived a moment later.
    private func findLine(attempt: Int) {
        guard let field, let dictated, before == nil else { return }
        if let snapshot = CaretAnchor.snapshot(of: field),
           let line = Self.line(holding: dictated, in: snapshot) {
            before = line
            Log.write("edit watch: watching \"\(line.prefix(60))\"")
            return
        }
        guard attempt < 6 else {
            Log.write("edit watch: the words never reached the field; not watching")
            stop()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.findLine(attempt: attempt + 1)
        }
    }

    func stop() {
        // The read that was waiting for you to stop typing, run before the
        // watch goes. Correcting a word and reaching straight for the hotkey is
        // the ordinary way to use this app, and cancelling here threw away
        // every correction made that way — which was all of them.
        if settling != nil {
            settling?.cancel()
            settling = nil
            read()
        }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        before = nil
        dictated = nil
        field = nil
        reported = []
    }

    deinit { stop() }

    /// A key went by. Read once the typing stops, not now — unless the key was
    /// the one that ends the line, which says the typing is over.
    private func look(_ event: NSEvent?) {
        if keysSeen == 0 { Log.write("edit watch: first key seen") }
        keysSeen += 1
        settling?.cancel()
        // Return and Enter. In a terminal the line is gone a moment later, so
        // waiting out the quiet period would read a field that no longer holds
        // what was corrected.
        if let event, event.keyCode == 36 || event.keyCode == 76 {
            settling = nil
            read()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.read() }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiet, execute: work)
    }

    private func read() {
        // Nothing to compare against until the line has been found.
        guard let before, let field else { return }
        guard Date().timeIntervalSince(lastLook) > 0.15 else { return }
        lastLook = Date()

        guard let whole = CaretAnchor.snapshot(of: field) else {
            Log.write("edit watch: the field would not give up its text this time")
            return
        }
        // The line again, found by what it still shares with the one that was
        // written. Anything else on the screen is somebody else's.
        guard let now = Self.nearest(to: before, in: whole) else {
            if reported.insert("lost").inserted {
                Log.write("edit watch: the line the words went on is no longer on screen")
            }
            return
        }
        if now == before {
            // Once per watch, so a field nobody touched does not fill the log.
            if reported.insert("still").inserted {
                Log.write("edit watch: read \(now.count) chars, unchanged")
            }
            return
        }
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

        return Change(was: was, now: became, sentence: now)
    }

    /// The line `text` sits on, or the whole thing if it is not there.
    static func line(holding text: String, in field: String) -> String? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        // The last one, not the first. A terminal shows its history, so the
        // words can appear higher up in something already printed — the first
        // real read latched onto this app's own log line quoting the sentence,
        // watched it, and reported it unchanged for ever. What was just typed
        // is at the bottom.
        for line in field.components(separatedBy: .newlines).reversed()
        where line.contains(wanted) {
            return line
        }
        // No line holds the words. In a terminal they are typed rather than
        // written, so the field can still be a keystroke behind. Falling back to
        // the whole field looked harmless and was not: nothing afterwards can
        // match a screen against a line, so every read reported the line as
        // gone.
        return nil
    }

    /// The line of `field` that is most nearly `wanted`.
    ///
    /// Nearness is what they share at the ends, which is the same measure the
    /// comparison itself uses. A line has to share more than half of `wanted`
    /// to be it: a terminal is full of short lines, and any of them shares a
    /// space or two with any other.
    static func nearest(to wanted: String?, in field: String) -> String? {
        guard let wanted, !wanted.isEmpty else { return nil }
        var best: String?
        var bestShared = 0
        // Bottom up, and `>` so a tie stays with the lower line — the one being
        // edited is the last one written. `>=` said the same in its comment and
        // did the opposite, handing every tie to whatever was higher up the
        // screen, which here was this app's own log.
        for line in field.components(separatedBy: .newlines).reversed() {
            let shared = Self.shared(wanted, line)
            if shared > bestShared { bestShared = shared; best = line }
        }
        // Two thirds, not half. A screen carrying this app's output has lines
        // that quote the sentence and share a great deal of it without being
        // it, and one changed word leaves far more than two thirds intact.
        return bestShared * 3 > wanted.count * 2 ? best : nil
    }

    /// How many characters two strings share at their two ends.
    private static func shared(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var front = 0
        while front < x.count, front < y.count, x[front] == y[front] { front += 1 }
        var back = 0
        while back < x.count - front, back < y.count - front,
              x[x.count - 1 - back] == y[y.count - 1 - back] { back += 1 }
        return front + back
    }
}
