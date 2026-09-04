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
        /// Which word of the line as it was written. Two occurrences of one
        /// word are two corrections, and telling them apart needs the place
        /// rather than the word. Keyed on the written line because that is the
        /// fixed baseline: the line on screen changes under every keystroke.
        let at: Int
        /// The same change's place in `sentence`, which is the line as it
        /// stands now. The two drift the moment an earlier change merges two
        /// words into one or splits one into two, so anything reading
        /// `sentence` by index has to use this one.
        let nowAt: Int
        /// The line as it was written, which `at` indexes. What a scorer
        /// needs is the text as heard, and `sentence` already has the fix in.
        let written: String
        /// How many words of `written` the change covers, from `at`.
        let span: Int
    }

    /// Every correction of one settling, handed over at once.
    ///
    /// At once because they are reviewed at once: several words fixed in one
    /// pass are one act, and one panel listing them is what that act deserves.
    var onCorrections: (([Change]) -> Void)?

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
    ///
    /// Keyed by where the word stood, not by the word. `before` does not change
    /// while the watch runs, so the place is a stable name for one correction —
    /// and keying by the word lost one of `versal is not versal` corrected to
    /// `Vercel is not Versailles`.
    private var seen: [Int: Change] = [:]
    /// What has been handed over already. The pending read in `stop` finds
    /// the same diff for as long as the line stands, and a correction declined
    /// at one press was offered again at the next.
    private var told: Set<String> = []
    private var lastLook = Date.distantPast
    /// The read waiting for you to stop typing. Cancelled and replaced by every
    /// key, so it only ever runs once the field has been still.
    private var settling: DispatchWorkItem?
    /// Keys seen since the watch started, so "nobody typed" can be told from
    /// "the read never ran".
    private var keysSeen = 0
    /// Which watch a queued retry belongs to.
    ///
    /// `start` can be called while the search for the line is still retrying —
    /// a rewrite from the correction panel does it. The queued retry then runs
    /// against the new field with the old attempt count, and at its last
    /// attempt it either takes a half-typed line as the baseline or stops the
    /// new watch outright.
    private var generation = 0

    /// How long the field has to be still before it is read.
    ///
    /// Reading on every key catches the edit half-typed: correcting `Versailles`
    /// to `Vercel` reported `Verce` first, which is not a word anybody meant.
    /// Long enough to type a name through, short enough to land before the next
    /// sentence is dictated.
    private static let quiet: TimeInterval = 1.2

    var isRunning: Bool { !monitors.isEmpty }

    /// When the dictation this watch is about landed. A change two seconds
    /// later is most likely a mishearing being fixed; five minutes later it
    /// is more likely a change of mind. Recorded, not decided on.
    private(set) var startedAt = Date()

    /// Watch the field the dictation just landed in.
    ///
    /// `snapshot` is the whole field as it stands now, not the dictation alone.
    /// Called again for every dictation: an older snapshot is not something
    /// anybody is still editing.
    func start(dictated words: String, in element: AXUIElement?) {
        generation += 1
        startedAt = Date()
        before = nil
        dictated = words
        field = element
        reported = []
        seen = [:]
        told = []
        keysSeen = 0
        guard Permissions.accessibility == .granted else {
            Log.write("edit watch: accessibility is not granted; corrections cannot be seen")
            return
        }
        // The monitors outlive one watch, so a second start reuses them. The
        // search for the line is started either way: returning early here left
        // a restarted watch with no baseline and nothing looking for one.
        guard monitors.isEmpty else {
            findLine(attempt: 0, generation: generation)
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
        findLine(attempt: 0, generation: generation)
    }

    /// The line the words landed on, once they are actually there.
    ///
    /// In a terminal ParrotFlow types rather than writes, so the field is a
    /// keystroke or two behind when the dictation is declared finished. Looking
    /// once found nothing and gave up; the words arrived a moment later.
    private func findLine(attempt: Int, generation: Int) {
        guard generation == self.generation else { return }
        guard let field, let dictated, before == nil else { return }
        let snapshot = CaretAnchor.snapshot(of: field)
        // Its size, not its contents. The field is a whole terminal or editor
        // and most of it was never dictated, so printing it put other people's
        // text and anything else on screen into the log. `--field-dump` prints
        // it on demand instead.
        if attempt == 0, let snapshot {
            let lines = snapshot.components(separatedBy: .newlines)
            Log.write("edit watch: field has \(snapshot.count) chars,"
                + " \(lines.count) line(s)")
        }
        if let snapshot,
           let line = Self.line(holding: dictated, in: snapshot),
           Self.holds(dictated, line) || attempt >= 40 {
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
            self?.findLine(attempt: attempt + 1, generation: generation)
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
        let changes = seen.values.sorted { $0.at < $1.at }
            .filter { told.insert("\($0.at)\u{1}\($0.now)").inserted }
        seen = [:]
        guard !changes.isEmpty else { return }
        // Both lines whole, so the log says what the diff ran over and not
        // only what it found. A 60-character prefix could not explain
        // `prone.maybe` becoming `prone point.maybe`.
        Log.write("edit watch: was \"\(before ?? "")\"")
        Log.write("edit watch: now \"\(changes[0].sentence)\"")
        for change in changes {
            Log.write("edit watch: \"\(change.was)\" became \"\(change.now)\"")
        }
        onCorrections?(changes)
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
        guard let now = Self.boxedInput(in: whole)
            ?? Self.promptLine(in: whole)
            ?? Self.nearest(to: before, in: whole)
        else {
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
        for change in found { seen[change.at] = change }
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
            let wasRun = old[fromI ..< i].joined(separator: " ")
            let nowRun = new[fromJ ..< j].joined(separator: " ")
            // Words added beside a word are not a correction of it. Asked
            // before the trim, which cuts a shared next sentence off the tail
            // and would make an insertion look like an append.
            guard !Self.added(was: wasRun, now: nowRun) else { continue }
            let pair = Self.trimmed(was: wasRun, now: nowRun)
            found.append(Change(
                was: pair.was, now: pair.now, sentence: now, at: fromI, nowAt: fromJ,
                written: before, span: i - fromI
            ))
        }
        return found
    }

    /// Whether one reading is the other with more words added beside it.
    ///
    /// Typing a name after a word, or pasting into the line, is not a
    /// correction of anything. `morning` became `morning Tasmeen` and
    /// `dictation.` became `dictation.[Image #17]`, and both were offered as
    /// vocabulary rules.
    ///
    /// The test is a whole word, not a prefix. `Ghost` to `Ghostty` extends the
    /// word itself and is a real correction; `Praisy` to `Praisy's` likewise.
    /// What is refused is one reading standing whole at the start or end of the
    /// other with a separate word beside it, so the rest has to hold a space
    /// for this to fire at all.
    ///
    /// Takes the two runs as they stood, not what `trimmed` returns. Only the
    /// punctuation both end on comes off here. `prone.maybe` became
    /// `prone point.maybe`, and the word went *inside* the run: cutting the
    /// shared `.maybe` first would leave `prone -> prone point`, which reads
    /// like a word appended and is a correction the panel has to keep.
    static func added(was: String, now: String) -> Bool {
        var a = Substring(was), b = Substring(now)
        while let last = a.last, last == b.last, !(last.isLetter || last.isNumber) {
            a = a.dropLast()
            b = b.dropLast()
        }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        guard short != long, long.contains(where: \.isWhitespace) else { return false }
        guard long.hasPrefix(short) || long.hasSuffix(short) else { return false }
        // A whole word has to have appeared, or `Ghost` growing into `Ghostty`
        // would read as `Ghost` with something added.
        let rest = long.hasPrefix(short)
            ? long.dropFirst(short.count) : long.dropLast(short.count)
        return rest.contains(where: \.isWhitespace)
    }

    /// The two readings with the punctuation they share taken off both.
    ///
    /// A word here is whatever stood between two spaces, and two dictations
    /// that ran together have none: "terminal.Ghost" became "terminal.Ghostty"
    /// and the whole run was offered as the rule. What was corrected is the
    /// letters, so the shared prompt, stop or comma comes off first.
    ///
    /// Only punctuation is cut, never letters. `Prizzy -> Praizy` shares "Pr"
    /// and "zy" and must survive whole; cutting shared letters would offer
    /// "iz -> aiz", which is not a word anybody said.
    ///
    /// The same at the tail. `prone.maybe` became `prone point.maybe`: the
    /// two share `.maybe`, and the second sentence is not part of the
    /// correction. It comes off from the first mark of the shared suffix.
    static func trimmed(was: String, now: String) -> (was: String, now: String) {
        let a = Array(was), b = Array(now)
        func plain(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        var shared = 0
        while shared < a.count, shared < b.count, a[shared] == b[shared] { shared += 1 }
        var head = 0
        for i in 0 ..< shared where !plain(a[i]) { head = i + 1 }

        var sharedTail = 0
        while sharedTail < a.count - head, sharedTail < b.count - head,
              a[a.count - 1 - sharedTail] == b[b.count - 1 - sharedTail] {
            sharedTail += 1
        }
        var tail = 0
        for i in 0 ..< sharedTail where !plain(a[a.count - 1 - i]) { tail = i + 1 }

        guard head + tail > 0, a.count - head - tail > 0, b.count - head - tail > 0
        else { return (was, now) }
        return (String(a[head ..< (a.count - tail)]), String(b[head ..< (b.count - tail)]))
    }

    /// The line as heard around the change, and where `was` stands in it.
    ///
    /// Twelve words either side, clipped to the line. That is the window the
    /// scorers read; the whole line is a terminal's input box and may hold
    /// several dictations. The words are joined with single spaces, so a row
    /// that wrapped comes back as one line, and the range is in characters
    /// of the text returned.
    static func asHeard(_ change: Change, margin: Int = 12) -> (text: String, range: Range<Int>) {
        let said = words(of: change.written)
        let end = min(said.count, change.at + change.span)
        guard change.at < end else { return (change.was, 0 ..< change.was.count) }
        let from = max(0, change.at - margin)
        let to = min(said.count, end + margin)
        let text = said[from ..< to].joined(separator: " ")
        let run = said[change.at ..< end].joined(separator: " ")
        let head = said[from ..< change.at].reduce(0) { $0 + $1.count + 1 }
        let inner = run.range(of: change.was).map { run.distance(from: run.startIndex, to: $0.lowerBound) } ?? 0
        let start = head + inner
        return (text, start ..< start + change.was.count)
    }

    // MARK: - the offer

    /// Why a change is not worth a panel.
    enum Refusal: CustomStringConvertible {
        /// Punctuation or case alone. Not a pronunciation.
        case punctuation
        /// Every word it lands on is one the word lists know.
        case ordinary

        var description: String {
            switch self {
            case .punctuation: return "punctuation, not a name"
            case .ordinary: return "ordinary English"
            }
        }
    }

    /// Punctuation or case alone, which is not a pronunciation. Spacing is:
    /// gluing two words into one is most of this vocabulary — `Red Rock` to
    /// `Redrock`, `Ghost T` to `Ghostty` — so the test that ignores
    /// punctuation must not ignore the space.
    static func onlyPunctuation(_ change: Change) -> Bool {
        let spaced = { (s: String) in
            String(s.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }).lowercased()
        }
        return spaced(change.was) == spaced(change.now)
    }

    /// Is this correction about a name, or about English?
    ///
    /// Spelling distance does not separate them. Measured on this speaker's
    /// own `heard:` lists against ordinary edits, `its -> it's` scores 1.000
    /// and `Prezi -> Praisy` 0.304, so any floor drawn through spelling keeps
    /// the noise and drops the names.
    ///
    /// The word the correction lands *on* does. On the same two sets the two
    /// word lists call 8 of 9 real corrections unknown and all 10 ordinary ones
    /// known. `Sentry` is the miss, and it is capitalised, so the capital is
    /// the second test — an `or`, so the day `Vercel` enters a dictionary it is
    /// still offered.
    ///
    /// Word by word. `prone -> prone point` was glued to `pronepoint` before it
    /// was looked up, and no list knows that, so a sentence being repaired was
    /// offered as a term. One name in the span is enough to offer it.
    static func refusal(
        for change: Change, unseen: (String) -> Bool = Vocabulary.unseenWord
    ) -> Refusal? {
        let letters = { (s: String) in String(s.filter { $0.isLetter || $0.isNumber }) }
        guard !onlyPunctuation(change) else { return .punctuation }
        let said = change.now.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (offset, word) in said.enumerated() {
            let bare = letters(word)
            guard !bare.isEmpty else { continue }
            if unseen(bare) { return nil }
            // A capital that is not the one every sentence starts with. The
            // first word of the *line* was not the right test: a line holds
            // several sentences, and correcting `Fais` to `Et` at the start of
            // one mid-line read as a name because of it.
            if bare.first?.isUppercase == true,
               !opensSentence(in: change.sentence, at: change.nowAt + offset) {
                return nil
            }
        }
        return .ordinary
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
        // Every kind of whitespace, not just spaces. A row that wrapped keeps
        // its newline, and `versatile\n` is not the word anybody corrected.
        return text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Whether the word at `at` opens a sentence on this line.
    ///
    /// The first word of the line does, and so does any word after one that
    /// ends in a stop. Both are places a capital means nothing.
    static func opensSentence(in line: String, at index: Int) -> Bool {
        guard index > 0 else { return true }
        let said = words(of: line)
        guard index - 1 < said.count else { return true }
        // The stop is not always the last character. `He said "hello."` ends
        // on a quote, `(that was it.)` on a bracket. So the whole run of
        // punctuation the word ends on is what gets asked, not one character.
        //
        // The run is empty for `Node.js`, which is what keeps a stop inside a
        // word from reading as the end of one.
        let before = said[index - 1]
        let tail = before.reversed().prefix { !$0.isLetter && !$0.isNumber }
        return tail.contains { ".!?".contains($0) }
    }

    /// What terminals and shells put in front of the line being typed.
    ///
    /// A terminal artefact and nothing more general: it is here because the
    /// field being watched is often a shell prompt, not because a chevron means
    /// anything anywhere else.
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
        if let boxed = boxedInput(in: field) { return boxed }
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

    /// What sits between the last two rules drawn across the screen.
    ///
    /// Claude Code puts its input box there, and that is the terminal this is
    /// for. Better than looking for the prompt on two counts: it says which
    /// program is in front rather than merely that something is, and a line long
    /// enough to wrap is still one box — the prompt is only on its first row, so
    /// looking for it lost every correction made further down.
    ///
    /// The rows are joined with a space. They are one sentence that ran out of
    /// width, not several.
    static func boxedInput(in field: String) -> String? {
        let lines = field.components(separatedBy: .newlines)
        guard let close = lines.lastIndex(where: isRule),
              let open = lines[..<close].lastIndex(where: isRule),
              close > open + 1
        else { return nil }
        let inside = lines[(open + 1) ..< close]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return inside.isEmpty ? nil : inside
    }

    /// A line drawn all the way across, which is what a box is made of.
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 20 else { return false }
        return trimmed.allSatisfy { rules.contains($0) }
    }

    private static let rules: Set<Character> = ["─", "-", "—", "═", "_"]

    /// Whether the line has most of the words in it yet.
    ///
    /// The box says where to look and this says when. Finding the box at once
    /// was the point of looking for it, and it took the baseline from an empty
    /// one: `watching "❯"`, before a character had been typed, against which
    /// the finished sentence read as no correction at all.
    ///
    /// Two thirds, and never more than that: by the time the last word lands
    /// the first may already have been corrected.
    static func holds(_ dictated: String, _ line: String) -> Bool {
        let wanted = words(of: dictated)
        guard !wanted.isEmpty else { return true }
        return shared(dictated, line) * 3 >= wanted.count * 2
    }
}
