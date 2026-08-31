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
    /// What each replaced word has become so far. Only the last state of each
    /// is a correction, so they are held here until the watch ends.
    private var seen: [String: Change] = [:]
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
        seen = [:]
        keysSeen = 0
        guard monitors.isEmpty else { return }
        guard Permissions.accessibility == .granted else {
            Log.write("edit watch: accessibility is not granted; corrections cannot be seen")
            return
        }

        // Key up, so the character is in the field by the time it is read. A
        // paste arrives as ⌘V, which is a key event too.
        // Key down for the line-ending keys and key up for the rest. Return is
        // read at once and has to be read before the app it went to acts on it:
        // in a terminal the line leaves the field on the press, and reading
        // after found a screen that no longer held what was corrected.
        let mask: NSEvent.EventTypeMask = [.keyUp, .keyDown]
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
        if let snapshot = CaretAnchor.snapshot(of: field) {
            // The whole field, once, while this is being built. Every failure
            // this watch has had came from a wrong idea of what a field holds,
            // and guessing at it cost more than printing it will.
            if attempt == 0 {
                let lines = snapshot.components(separatedBy: .newlines)
                Log.write("edit watch: field has \(snapshot.count) chars,"
                    + " \(lines.count) line(s)")
                for (number, line) in lines.enumerated() where !line.isEmpty {
                    Log.write(String(format: "    %3d | %@", number + 1,
                                     String(line.prefix(110))))
                }
            }
        }
        if let snapshot = CaretAnchor.snapshot(of: field),
           let line = Self.line(holding: dictated, in: snapshot) {
            before = line
            Log.write("edit watch: watching \"\(line.prefix(60))\"")
            return
        }
        guard attempt < 40 else {
            Log.write("edit watch: the words never reached the field; not watching")
            stop()
            return
        }
        // Eight seconds in all. A long sentence is typed into a terminal one
        // character at a time, and an 84-character one was still arriving when
        // three seconds gave up on it. Nothing is read until the line is found,
        // so waiting costs only the wait.
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
        tell()
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
            guard event.type == .keyDown else { return }
            settling = nil
            read()
            tell()
            return
        }
        // Everything else is read once you stop, and only on the way up, so a
        // held key is not one read per repeat.
        guard event == nil || event?.type == .keyUp else { return }
        let work = DispatchWorkItem { [weak self] in self?.read() }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiet, execute: work)
    }

    /// Hand over what was found, once, in the order it was found.
    private func tell() {
        guard !seen.isEmpty else { return }
        let changes = seen.values.sorted { $0.was < $1.was }
        seen = [:]
        for change in changes {
            Log.write("edit watch: \"\(change.was)\" became \"\(change.now)\"")
            onChange?(change)
        }
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
        // The same way it was found: a prompt line is the prompt line whatever
        // it now says, and looking for it by resemblance would lose it exactly
        // when it has changed most.
        guard let now = Self.promptLine(in: whole) ?? Self.nearest(to: before, in: whole) else {
            if reported.insert("lost").inserted {
                Log.write("edit watch: the line the words went on is no longer on screen")
            }
            return
        }
        if now == before {
            if reported.insert("still").inserted {
                Log.write("edit watch: read \(now.count) chars, unchanged")
            }
            return
        }
        let found = Self.changes(from: before, to: now)
        guard !found.isEmpty else {
            if reported.insert("skip\u{1}" + now).inserted {
                Log.write("edit watch: nothing in \"\(now.prefix(60))\" reads as a correction")
            }
            return
        }
        // Kept, not told. A correction typed in stages passes through states
        // nobody meant — deleting `Prezi` back to `P` before typing `Praisy`
        // reported `Prezi -> P` as a correction — and only the last state is
        // one. Told when the watch ends, which is when you move on.
        for change in found { seen[change.was] = change }
    }

    // MARK: - the comparison

    /// Every word that was replaced by another, in order.
    ///
    /// Word by word, not by the two ends. Comparing what two lines share at
    /// their front and back works for one change and collapses for two: the
    /// prefix stops at the first and the suffix at the last, so the whole
    /// middle counts as different. On "So we have Prezi in our team. She's an
    /// expert about the versal platform" with both names corrected, that measure
    /// found 33% in common and decided the line had left the screen.
    ///
    /// A run where one word became one word is a correction. A run of two words
    /// against three is a rewrite of a phrase, and there is no telling which
    /// part of it was meant, so it is left alone.
    static func changes(from before: String, to now: String) -> [Change] {
        guard before != now else { return [] }
        let old = words(of: before), new = words(of: now)
        guard !old.isEmpty, !new.isEmpty else { return [] }

        // Longest common subsequence, then walk it: the gaps between what the
        // two lines share are the edits.
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1),
                            count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var found: [Change] = []
        var i = 0, j = 0
        // `||`, not `&&`. A change at the very last word leaves one side spent
        // while the other still has the word that replaced it, and stopping
        // there lost every correction of a sentence's final word.
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] { i += 1; j += 1; continue }
            let fromI = i, fromJ = j
            while i < old.count || j < new.count {
                if i < old.count, j < new.count, old[i] == new[j] { break }
                if i < old.count, j >= new.count || table[i + 1][j] >= table[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
            let left = i - fromI, right = j - fromJ
            // One word for one, and one word for two either way: the recogniser
            // splits a name as often as it mangles it, and `Ghost D` becoming
            // `Ghostty` is the same correction as `Prezi` becoming `Praisy`.
            // Two words for two is a phrase, and there is no telling which part
            // of it was meant.
            guard left >= 1, right >= 1, left <= 2, right <= 2, left + right <= 3
            else { continue }
            found.append(Change(
                was: old[fromI ..< i].joined(separator: " "),
                now: new[fromJ ..< j].joined(separator: " "),
                sentence: now
            ))
        }
        return found
    }

    /// The words of a line, punctuation kept: `Vercel.` and `Vercel` are not the
    /// same correction, and the one with the stop is what was on the screen.
    ///
    /// The prompt is not a word. A terminal draws one at the head of the line
    /// you are typing into, and it corrected `❯ Prizzy` to `❯ Praizy` — true,
    /// and not a correction of anything.
    private static func words(of line: String) -> [String] {
        var text = Substring(line).drop(while: { $0.isWhitespace })
        if let first = text.first, Self.prompts.contains(first) {
            text = text.dropFirst().drop(while: { $0.isWhitespace })
        }
        return text.split(separator: " ").map(String.init)
    }

    /// What terminals and shells put in front of the line being typed.
    private static let prompts: Set<Character> = ["❯", ">", "$", "%", "#", "›", "→"]

    /// The line the words went on.
    ///
    /// The prompt first. A terminal draws one at the head of the line you are
    /// typing into, so that line can be picked out **before the words arrive**
    /// — and the wait for them to arrive is what lost the longest sentence of
    /// every test: eighty-four characters typed one at a time outran every
    /// budget it was given.
    ///
    /// Resemblance is the fallback, for a real text field where the whole value
    /// is the text and there is no prompt to look for.
    static func line(holding text: String, in field: String) -> String? {
        if let prompt = promptLine(in: field) { return prompt }
        return nearest(to: text.trimmingCharacters(in: .whitespacesAndNewlines), in: field)
    }

    /// The last line that starts with a prompt.
    ///
    /// From the bottom, because a terminal shows its history and a prompt
    /// character can sit anywhere in what has already been printed. The one
    /// being typed into is the last.
    static func promptLine(in field: String) -> String? {
        for line in field.components(separatedBy: .newlines).reversed() {
            let trimmed = line.drop(while: { $0.isWhitespace })
            guard let first = trimmed.first, prompts.contains(first) else { continue }
            // A prompt with nothing after it is a shell waiting, not a line
            // somebody is editing.
            guard trimmed.dropFirst().contains(where: { !$0.isWhitespace }) else { continue }
            return line
        }
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
        return bestShared * 3 > words(of: wanted).count * 2 ? best : nil
    }

    /// How many words two lines have in common, counting repeats once each.
    ///
    /// Not what they share at the ends. Two corrections in one line leave the
    /// ends agreeing on almost nothing while every other word is untouched, and
    /// the ends measure said the line had gone.
    private static func shared(_ a: String, _ b: String) -> Int {
        var pool: [String: Int] = [:]
        for word in words(of: a) { pool[word, default: 0] += 1 }
        var count = 0
        for word in words(of: b) {
            guard let left = pool[word], left > 0 else { continue }
            pool[word] = left - 1
            count += 1
        }
        return count
    }
}
