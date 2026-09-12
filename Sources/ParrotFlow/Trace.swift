import FluidAudio
import Foundation

/// One JSON object per dictation, appended to `trace.jsonl` beside the
/// recordings it describes.
///
/// `ParrotFlow.log` is for reading over someone's shoulder while something is
/// going wrong: prose, second resolution, and a rolling buffer that throws the
/// oldest away. That makes it the wrong place to keep what the decoder
/// actually said. The interesting questions here are asked over hundreds of
/// dictations at once — which words does the model get least sure about, does
/// a dropped ending come from the decoder or the speech gate, what does a
/// prompt stage really cost — and none of them survive a file that truncates
/// itself, or a format you have to parse back out of English.
///
/// So: one line per dictation, never rotated, joined to its audio by
/// `wav`. The decoder already computes every number in here and we used to
/// drop it on the floor one line after it arrived.
///
/// Collected through a task local rather than an extra parameter on nine
/// functions. A dictation is one task from the decoder to the last pipeline
/// stage, which is exactly the scope a task local has; the alternative was
/// threading a collector through `Pipeline.run`, `apply` and `runPrompt` for
/// the sake of a debug artefact.
enum Trace {

    /// The shape of a line. Records written before this existed have no `v` at
    /// all, which reads as 1 — two of them, from the afternoon this was built.
    ///
    /// One field, and the only moment it is free is before there is anything to
    /// migrate. A reader three months from now needs to know which shape it is
    /// holding without inferring it from which keys happen to be present.
    ///
    /// 3 replaced a stage's `before` and `after` with `edits`, and added the
    /// numbers a timeline needs: the press, the gate's own cost, the model
    /// load, and one row per decode arm. Older lines are never converted —
    /// nothing in 3 is derivable from 2 except `edits`, and a line claiming a
    /// shape it does not have is exactly what this field exists to prevent.
    static let version = 3

    /// The dictation being traced right now, if any. Nil on every path that
    /// did not ask for a trace — nothing here runs unless a collector is bound.
    @TaskLocal static var current: Collector?

    /// Where a trace comes from, so a sweep re-run over the archive can be told
    /// apart from the dictations someone actually spoke.
    enum Source: String {
        case live
        case cli
    }

    /// Which kind of line this is. Corrections are not dictations — they arrive
    /// minutes later, from a panel or the terminal — but they belong in the same
    /// file, because the question they answer is about the dictation they
    /// followed. `jq 'select(.kind == "correction")'` separates them.
    enum Kind: String {
        case dictation
        case correction
        case edit
        case chose
    }

    /// The app a dictation was spoken into.
    ///
    /// Both halves, because they answer different questions: the bundle id is
    /// what survives a rename and what a query should group on, and the name is
    /// what a human reads. Until now only the name was kept, while `app:`
    /// conditions were matching against both.
    ///
    /// Deliberately *not* the window title. It is the highest-yield field on
    /// offer and the one that leaks hardest — document names, client names,
    /// ticket subjects — and nothing here needs it.
    struct App: Encodable {
        let name: String
        let bundleID: String

        enum CodingKeys: String, CodingKey {
            case name
            case bundleID = "bundle_id"
        }
    }

    // MARK: - Collecting

    /// Gathers one dictation's record as it happens.
    ///
    /// A class with a lock rather than an actor: every writer here is a
    /// synchronous call sitting next to an existing `Log.write`, and making
    /// them all `await` would have been the whole invasive change again.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()

        private let wav: String
        /// Readable from outside: the seam log names the run it describes, and
        /// "live or replay" is exactly what this field already knows.
        let source: Source
        private var asr: ASR?
        private var vad: VAD?
        private var capture: Capture?
        private var stages: [Stage] = []
        private var final: String?
        private var lang: String?
        private var spans: [Span] = []
        private var nextID = 1
        private var prepare: Double?
        /// Which decode the transcript came from. The first pass until an arm
        /// beats it — a dictation always has a taken arm, and leaving this nil
        /// would report every clean decode as one nobody used.
        private var takenArm = "decode pass 1"
        /// Zero on the timeline. The press for a live dictation, so the span
        /// covering the recording itself starts at 0 rather than at a negative
        /// number; the moment the collector was made for a replay, which was
        /// never pressed for.
        ///
        /// Set here rather than by a later `record*` call, so a span opened
        /// before anything else has the same zero as one opened after.
        private let origin: Date

        init(wav: String, source: Source, origin: Date) {
            self.wav = wav
            self.source = source
            self.origin = origin
        }

        /// What a span opened right now hangs under. A stage sets it while it
        /// runs, so a part opened deep inside `SentenceJoin` is filed under the
        /// stage that called it without anyone threading an id through.
        private var openParent: Int?

        /// Opens a span and returns what closes it.
        ///
        /// The close is the write, so that is where the lock is taken — an
        /// arm's span is closed from its own task and several arms run at once.
        /// - Parameter nests: whether spans opened while this one is open
        ///   belong to it. True for a stage, false for everything else.
        func open(_ name: String, kind: Span.Kind, nests: Bool = false) -> OpenSpan {
            lock.lock()
            let id = nextID
            nextID += 1
            let parent = openParent
            if nests { openParent = id }
            lock.unlock()
            return OpenSpan(id: id, name: name, kind: kind, parent: parent, nests: nests,
                            at: Date().timeIntervalSince(origin), collector: self)
        }

        /// Seconds since the origin. No lock: `origin` never changes.
        fileprivate func elapsed() -> Double { Date().timeIntervalSince(origin) }

        fileprivate func close(_ span: Span, restoring: Bool) {
            lock.lock(); defer { lock.unlock() }
            if restoring { openParent = span.parent }
            // A dictation cannot need more than this, and a runaway one must
            // not grow without end for the sake of a debug artefact.
            guard spans.count < Trace.spanLimit else { return }
            spans.append(span)
        }

        fileprivate func timeline(app: App?) -> Timeline? {
            lock.lock(); defer { lock.unlock() }
            guard !spans.isEmpty else { return nil }
            return Timeline(
                v: Trace.spansVersion, kind: Kind.dictation.rawValue,
                t0: Trace.stamp(origin, fractional: true), wav: wav,
                source: source.rawValue, app: app, lang: lang,
                spans: spans.sorted { $0.at < $1.at }, final: final
            )
        }

        /// Which language the transcript was judged to be in.
        ///
        /// Ours, not Parakeet's — `ASRResult` carries no language and
        /// `TokenLanguageFilter` takes a hint rather than reporting one, so
        /// there is nothing to log from the model. It is what a
        /// `when: language == "fr"` condition reads and what `numbers`
        /// resolves its grammar with.
        func recordLanguage(_ language: String) {
            lock.lock(); defer { lock.unlock() }
            lang = language
        }

        func recordASR(_ result: ASRResult, model: String) {
            lock.lock(); defer { lock.unlock() }
            asr = ASR(
                model: model,
                arm: spans.contains { $0.kind == .decode } ? takenArm : nil,
                text: result.text,
                confidence: result.confidence,
                duration: result.duration,
                processing: result.processingTime,
                words: Trace.words(from: result.tokenTimings ?? [])
            )
        }

        func recordVAD(
            speech: Double, total: Double, segments: [(Double, Double)], seconds: Double? = nil
        ) {
            lock.lock(); defer { lock.unlock() }
            vad = VAD(
                seconds: seconds, speech: speech, total: total,
                segments: segments.map { [$0.0, $0.1] }
            )
        }

        /// What loading the models cost, when they were not already up.
        func recordPrepare(_ seconds: Double) {
            lock.lock(); defer { lock.unlock() }
            prepare = seconds
        }

        /// Which decode the transcript came from, named as its span is.
        func recordArm(_ arm: String) {
            lock.lock(); defer { lock.unlock() }
            takenArm = arm
        }

        /// How long the press waited, in seconds, before the engine was running
        /// and before the microphone delivered anything.
        ///
        /// Both from the press, so the difference between them is the device's
        /// own start-up. Everything before `firstSample` is speech that was
        /// said into a microphone that was not yet recording — the clips that
        /// begin mid-word have no other explanation, and until this field there
        /// was nothing on disk that could size it.
        func recordCapture(
            engine: Double?, firstSample: Double?, at: Date? = nil, stopped: Double? = nil
        ) {
            lock.lock(); defer { lock.unlock() }
            capture = Capture(
                at: at.map { Trace.stamp($0, fractional: true) },
                engine: engine, firstSample: firstSample, stopped: stopped
            )
        }

        /// - Parameter code: the category, for grouping. The prose beside it
        ///   names the actual pattern that did or did not match, which is what
        ///   you need to fix a condition — and which is useless for counting,
        ///   because every stage phrases it differently.
        func recordSkip(_ name: String, code: String, reason: String) {
            lock.lock(); defer { lock.unlock() }
            stages.append(Stage(name: name, skipCode: code, skipped: reason))
        }

        /// Every stage that ran, including the ones that changed nothing —
        /// "ran and found nothing" and "was skipped" are different answers and
        /// only the log conflates them.
        func recordStage(
            _ name: String, before: String, after: String, seconds: Double,
            vars: [String: Scope.Value] = [:]
        ) {
            lock.lock(); defer { lock.unlock() }
            stages.append(
                Stage(name: name, before: before, after: after, seconds: seconds, vars: vars)
            )
        }

        /// What was actually delivered. Left nil by a dictation that threw on
        /// the way there, which is worth being able to see.
        func recordFinal(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            final = text
        }

        /// Everything gathered so far, for a `returns: json` transform.
        ///
        /// The same fields the record on disk carries, encoded by the same
        /// types, so the file a sweep reads and the payload a script reads
        /// cannot drift into two shapes.
        ///
        /// Mid-pipeline, so `stages` is what has run *before* this one and
        /// `final` does not exist yet. `asr`, `vad` and `lang` are complete:
        /// all of it is settled before the first stage starts.
        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(wav: wav, source: source.rawValue, lang: lang,
                            asr: asr, vad: vad, stages: stages)
        }

        fileprivate func record(at: String, app: App?) -> Record {
            lock.lock(); defer { lock.unlock() }
            // Read off the timeline rather than gathered twice. A part is a
            // span whose parent is a stage's span, and a decode is a span of
            // that kind — so the two files cannot disagree about what a step
            // cost, which is the whole reason they were built from one source.
            let byID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
            var parts: [String: [Part]] = [:]
            for span in spans where span.kind == .part || span.kind == .model {
                guard let parent = span.parent.flatMap({ byID[$0] }),
                      parent.kind == .stage else { continue }
                parts[parent.name, default: []]
                    .append(Part(name: span.name, seconds: span.dur, note: span.note))
            }
            let decodes = spans.filter { $0.kind == .decode }.map {
                Decode(arm: $0.name, seconds: $0.dur,
                       reached: Trace.reached($0.note), taken: $0.name == takenArm)
            }
            return Record(
                v: Trace.version, kind: Kind.dictation.rawValue,
                at: at, wav: wav, source: source.rawValue, app: app, lang: lang,
                asr: asr, vad: vad, capture: capture, prepare: prepare,
                decodes: decodes.isEmpty ? nil : decodes,
                stages: stages.map { stage in
                    var stage = stage
                    stage.parts = parts[stage.name]
                    return stage
                },
                final: final
            )
        }
    }

    // MARK: - Writing

    /// Runs `body` with a collector bound, then appends what it gathered.
    ///
    /// Writes the line whether or not the body threw: a dictation that failed
    /// halfway is the one you most want the decoder's numbers for.
    /// - Parameter beside: the directory to write the line into. Pass the one
    ///   holding the clip; the global is only a fallback for callers that have
    ///   no clip on disk to point at.
    /// - Parameter origin: zero on the timeline. The press, for a live
    ///   dictation: this runs after the recording has stopped, so a collector
    ///   that stamped its own start would put the recording at negative time.
    static func record<T>(
        wav: String, source: Source, app: App? = nil, beside: URL? = nil,
        origin: Date = Date(), body: () async throws -> T
    ) async rethrows -> T {
        let collector = Collector(wav: wav, source: source, origin: origin)
        // Taken from where the clip actually is, not from the global, and not
        // snapshotted at a moment chosen for being early.
        //
        // `output_dir` can change on any save of config.yaml — the file is
        // watched and reloaded live — so any read of the global is a read at
        // some particular instant, and there is no instant late enough to be
        // right and early enough to be safe. Reading it when the record is
        // finished loses to a save during a prompt stage. Reading it when the
        // dictation starts loses to a save between the clip being written and
        // this task being scheduled. Both file the line in one directory while
        // the clip it names sits in the other, and `wav` is a bare filename, so
        // that separation is the one thing that breaks the join.
        //
        // The clip's own URL has no such instant: it is where the file went,
        // whatever the config said at the time or says now.
        let directory = beside ?? Self.directory
        defer {
            append(collector.record(at: stamp(), app: app), to: directory)
            // Its own file, and only when asked for. The corpus answers
            // questions across every dictation ever given and so may never be
            // deleted; a timeline answers one question about one dictation and
            // is only ever wanted for a recent one. Splitting them is what lets
            // this one be thrown away.
            if spansEnabled, let timeline = collector.timeline(app: app) {
                append(timeline, to: directory, named: spansFile)
            }
        }
        return try await $current.withValue(collector) { try await body() }
    }

    /// Writes down a rule someone taught the app.
    ///
    /// Its own line rather than a field on a dictation: a correction arrives
    /// minutes after the transcript it is about, from a panel or the terminal,
    /// long past the task that carried the collector. Joining the two is a
    /// question for whoever reads the file, and `at` is enough to do it.
    ///
    /// - Parameter via: which path taught it — `panel`, `inline` or `learn`.
    static func correction(heard: String, corrected: String, via: String) {
        append(
            Correction(
                v: version, kind: Kind.correction.rawValue, at: stamp(),
                heard: heard, corrected: corrected, via: via
            ),
            to: directory
        )
    }

    /// Writes down a word changed by hand. See `Edit`.
    /// - Parameter beside: the directory holding the dictation's clip, so the
    ///   edit and the dictation it is about are in one file. See `record`.
    static func edit(
        heard: String, corrected: String, text: String, range: Range<Int>,
        lang: String, app: String?, after: TimeInterval, beside: URL? = nil
    ) {
        append(
            Edit(
                v: version, kind: Kind.edit.rawValue, at: stamp(),
                heard: heard, corrected: corrected, text: text,
                range: [range.lowerBound, range.upperBound], lang: lang, app: app,
                after: (after * 10).rounded() / 10
            ),
            to: beside ?? directory
        )
    }

    /// Writes down a place the app could not settle, and what you said it was.
    ///
    /// Its own kind, not an `edit`. An edit is a thing the app got wrong and
    /// you fixed. This is a place the app said out loud it could not tell, so
    /// the answer is a label on a case that is known to be hard, whichever way
    /// it went. Mixed into the edits they would read as mistakes that were
    /// never made, and the edit corpus is what the misheard-word work reads.
    ///
    /// - Parameter kept: what stood there, which is what ships unanswered.
    /// - Parameter chose: what was picked. The same string as `kept` when the
    ///   answer was to keep it, and that is the label that costs nothing
    ///   anywhere else to collect.
    static func chose(
        term: String, kept: String, chose: String, text: String, range: Range<Int>,
        lang: String, app: String?, after: TimeInterval, beside: URL? = nil
    ) {
        append(
            Chose(
                v: version, kind: Kind.chose.rawValue, at: stamp(),
                term: term, kept: kept, chose: chose, text: text,
                range: [range.lowerBound, range.upperBound], lang: lang, app: app,
                after: (after * 10).rounded() / 10
            ),
            to: beside ?? directory
        )
    }

    /// What it cost to put the words where they were going.
    ///
    /// Its own line rather than a span on the dictation: `record` appends in a
    /// `defer`, and delivery happens after that — held open, a dictation that
    /// threw would stop writing the numbers explaining why. So the contract
    /// stays "append on exit, even if it threw", and this joins by `wav`.
    static func deliver(wav: String, seconds: Double, route: String, app: String?, beside: URL?) {
        guard spansEnabled else { return }
        append(
            Delivery(
                v: spansVersion, kind: "deliver", at: stamp(fractional: true),
                wav: wav, seconds: seconds, route: route, app: app
            ),
            to: beside ?? directory, named: spansFile
        )
    }

    fileprivate struct Delivery: Encodable {
        let v: Int
        let kind: String
        let at: String
        let wav: String
        let seconds: Double
        let route: String
        let app: String?
    }

    private static let queue = DispatchQueue(label: "com.parrotflow.trace")

    /// Waits for queued writes to reach the file. Same reason as `Log.flush` —
    /// a CLI process exits before the queue drains.
    static func flush() {
        queue.sync {}
    }

    /// Where `trace.jsonl` goes — the recordings directory, so a clip and its
    /// trace live together. Set from the config at launch, because the stages
    /// that write here are handed a transcript and nothing else.
    nonisolated(unsafe) static var directory: URL?

    /// Appends one line, atomically against every other writer of this file.
    ///
    /// Two processes write here by design: the menu bar app, and a
    /// `--transcribe` sweep over the archive — which `cli.md` recommends
    /// running, and which nobody is going to quit the app before starting.
    /// Seeking to the end and then writing is two steps, and both processes
    /// can take the first before either takes the second, which loses a line
    /// or splices two into something no longer parseable as JSONL.
    ///
    /// `O_APPEND` collapses those two steps into one the kernel does not
    /// interleave, which `FileHandle(forWritingTo:)` does not ask for. The
    /// serial queue still orders this process's own writes and keeps them off
    /// the caller's thread; it just cannot say anything about the other
    /// process.
    ///
    /// Deliberately no size cap. This is the corpus, not a debug buffer: a year
    /// of heavy use is a few megabytes, and the whole point is being able to
    /// ask a question of every dictation you have ever given.
    /// How large `spans.jsonl` may get before the current one is set aside.
    ///
    /// The corpus has no cap and must not have one — it is what you ask
    /// questions of years later. A timeline is the opposite: only ever wanted
    /// for something recent, and about ten times the size. So this one rotates,
    /// which is what lets it be on for everybody.
    static let spansLimit = 64 * 1024 * 1024

    /// Renames the file aside and starts a new one, keeping one generation.
    ///
    /// A rename rather than `Log`'s truncate-to-zero: truncating throws away
    /// the timeline you were about to look at. Another process holding the old
    /// descriptor keeps writing to the renamed file, which costs a line and
    /// cannot corrupt one.
    private static func rotateIfLarge(_ url: URL) {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size > spansLimit else { return }
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("spans.1.jsonl")
        try? fm.removeItem(at: aside)
        try? fm.moveItem(at: url, to: aside)
    }

    private static func append<Line: Encodable>(
        _ record: Line, to directory: URL?, named file: String = "trace.jsonl"
    ) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(file)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)  // one object per line, so `jq -c` and friends work

        queue.async {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            if file == spansFile { rotateIfLarge(url) }
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                // One call, so the append stays the single atomic act O_APPEND
                // promises. A short write would mean a torn line, and there is
                // nothing useful to do about it but stop.
                _ = write(fd, base, buffer.count)
            }
        }
    }

    /// The `reached 3.52s` a decode span writes, as a number.
    ///
    /// Parsed back rather than carried twice: the note is what a person reads
    /// on the timeline, and a second field holding the same figure is a second
    /// field to keep in step.
    fileprivate static func reached(_ note: String?) -> Double? {
        guard let note, note.hasPrefix("reached "), note.hasSuffix("s") else { return nil }
        return Double(note.dropFirst("reached ".count).dropLast())
    }

    // MARK: - What a stage changed

    /// The changes between two versions of a sentence, in the first one's
    /// coordinates.
    ///
    /// This replaces keeping both strings. Stage `before`/`after` was a quarter
    /// of the corpus and 93.6% of it was one sentence written twice to say
    /// nothing had happened, which `changed` already said.
    ///
    /// **No `String.Index` anywhere.** Swift traps on an out-of-range index,
    /// and this runs on every stage of every dictation — a debug artefact must
    /// not be able to stop a transcript. Character arrays and integer offsets
    /// cannot trap, and a hunk that cannot be built is dropped rather than
    /// guessed at.
    static func edits(from before: String, to after: String) -> [Change] {
        guard before != after else { return [] }
        let old = Array(before)
        let new = Array(after)
        // Bounded: a pathological pair must not cost a dictation. Above this
        // the change is stated as one hunk, which stays true and stays cheap.
        guard old.count + new.count <= 20_000 else {
            return [Change(at: 0, was: before, now: after)]
        }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var edits: [Change] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            let cut = (i < old.count && removed.contains(i))
                || (j < new.count && inserted.contains(j))
            guard cut else {
                i += 1
                j += 1
                continue
            }
            let at = i
            var was = ""
            var now = ""
            while i < old.count, removed.contains(i) {
                was.append(old[i])
                i += 1
            }
            while j < new.count, inserted.contains(j) {
                now.append(new[j])
                j += 1
            }
            // Neither side moved, so the walk would not either. Cannot happen
            // with a difference this loop built its sets from; stopping beats
            // spinning if it ever does.
            if was.isEmpty, now.isEmpty { break }
            edits.append(Change(at: at, was: was, now: now))
        }
        return edits
    }

    /// Applies edits to the text they were measured against.
    ///
    /// The inverse of `edits`, and the only reason either is worth keeping: a
    /// stage's input and output are no longer both on disk, so replaying is how
    /// anyone gets the output back. Nil where an edit does not fit, which is a
    /// corpus that has gone wrong and must read as one rather than as a
    /// plausible sentence — see `--trace-edits`.
    static func replay(_ edits: [Change], over text: String) -> String? {
        var chars = Array(text)
        var delta = 0
        for edit in edits {
            let start = edit.at + delta
            let was = Array(edit.was)
            guard start >= 0, start + was.count <= chars.count else { return nil }
            guard Array(chars[start..<(start + was.count)]) == was else { return nil }
            chars.replaceSubrange(start..<(start + was.count), with: Array(edit.now))
            delta += edit.now.count - was.count
        }
        return String(chars)
    }

    /// What a stage changed, in words, for its span's note.
    ///
    /// Words rather than the character runs `edits` returns. Those are minimal,
    /// so `borderplay` to `boilerplate` comes back as two runs inside one word
    /// and reads as noise. The corpus keeps the exact coordinates; this is the
    /// line a person reads next to the step that made it.
    ///
    /// A side that is empty renders as `""`, so a deletion and an insertion are
    /// told apart from a swap without a legend.
    static func changeSummary(from before: String, to after: String) -> String? {
        guard before != after else { return nil }
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var runs: [String] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            let cut = (i < old.count && removed.contains(i))
                || (j < new.count && inserted.contains(j))
            guard cut else { i += 1; j += 1; continue }
            var was: [String] = []
            var now: [String] = []
            while i < old.count, removed.contains(i) { was.append(old[i]); i += 1 }
            while j < new.count, inserted.contains(j) { now.append(new[j]); j += 1 }
            if was.isEmpty, now.isEmpty { break }
            runs.append("\(side(was)) -> \(side(now))")
        }

        // The strings differ but no word does, so by construction the only
        // thing between them is whitespace. `join` is the stage that does
        // this, and saying nothing would read as a step that did nothing.
        guard !runs.isEmpty else { return "spacing" }

        var note = ""
        for (index, run) in runs.enumerated() {
            let joined = note.isEmpty ? run : note + ", " + run
            guard joined.count <= noteLimit else {
                return note.isEmpty
                    ? String(run.prefix(noteLimit)) + "…"
                    : note + ", +\(runs.count - index) more"
            }
            note = joined
        }
        return note
    }

    /// How many characters of `changeSummary` reach a span's note. The
    /// timeline already spends 85 columns on the name, the number and the bar,
    /// and a row that wraps is a row nobody reads.
    private static let noteLimit = 56

    /// One half of a change. A run longer than this is a rewrite, and printing
    /// it would put the sentence in `spans.jsonl`.
    private static func side(_ words: [String]) -> String {
        guard !words.isEmpty else { return "\"\"" }
        guard words.count <= 6 else { return "\(words.count) words" }
        return words.joined(separator: " ")
    }

    /// One change a stage made. `at` is a character offset into the text that
    /// stage was handed, so a list of these applies left to right with a
    /// running delta, or right to left with none.
    ///
    /// Not `Edit`: that is a whole line of the file, written when somebody
    /// corrects a word by hand. This is a field on a stage.
    struct Change: Encodable, Sendable {
        let at: Int
        let was: String
        let now: String
    }

    // MARK: - Words

    /// Sub-word tokens grouped into words, keeping the confidence FluidAudio's
    /// own `buildWordTimings` drops.
    ///
    /// Confidence is the reason this file exists — a word the decoder was
    /// unsure of is a candidate for `transcription.replacements`, and ranking
    /// those beats guessing at them. The word keeps its *lowest* token's
    /// confidence: a name that came through as one solid piece and one shaky
    /// one is a shaky name, and averaging hides exactly that.
    static func words(from timings: [TokenTiming]) -> [Word] {
        grouped(from: timings).map(\.word)
    }

    /// The same grouping, with the tokens each word was built from.
    ///
    /// One implementation, because a caller that cuts words off a decode has to
    /// cut the tokens the same way. A second copy of this loop would drift.
    static func grouped(from timings: [TokenTiming]) -> [(word: Word, tokens: Range<Int>)] {
        var words: [(word: Word, tokens: Range<Int>)] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var confidence = Float.greatestFiniteMagnitude
        var first = 0
        var last = 0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            words.append((
                Word(word: trimmed, start: start, end: end, confidence: confidence),
                first..<(last + 1)
            ))
        }

        for (index, timing) in timings.enumerated() {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }

            // SentencePiece marks a word's first piece with `▁`; the tokenizer
            // hands some of them back already rendered as a leading space.
            if token.hasPrefix("\u{2581}") || token.hasPrefix(" ") || text.isEmpty {
                if !text.isEmpty { flush() }
                text = token.replacingOccurrences(of: "\u{2581}", with: "")
                start = timing.startTime
                confidence = timing.confidence
                first = index
            } else {
                text += token
                confidence = min(confidence, timing.confidence)
            }
            end = timing.endTime
            last = index
        }
        flush()
        return words
    }

    // MARK: - Shape on disk

    /// - Parameter fractional: milliseconds as well as seconds. A timeline
    ///   measured to the millisecond cannot be joined to a zero stated to the
    ///   second, and `NSLog` timestamps are sub-second too.
    static func stamp(_ date: Date = Date(), fractional: Bool = false) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// What a `returns: json` transform is handed as `trace`.
    ///
    /// Internal where `Record` is fileprivate, because this one leaves the
    /// file. Same members, so the two cannot describe different things.
    struct Snapshot: Encodable {
        let wav: String
        let source: String
        let lang: String?
        fileprivate let asr: ASR?
        fileprivate let vad: VAD?
        /// What ran before the stage reading this. Not the whole pipeline.
        fileprivate let stages: [Stage]

        /// What the decoder wrote, for a caller checking whether the text it
        /// holds is still that. Nil outside a dictation.
        var decodedText: String? { asr?.text }
    }

    fileprivate struct Record: Encodable {
        let v: Int
        let kind: String
        let at: String
        let wav: String
        let source: String
        let app: App?
        let lang: String?
        let asr: ASR?
        let vad: VAD?
        let capture: Capture?
        /// Seconds spent loading models before this dictation could start.
        /// Absent when they were already warm, which is almost always.
        let prepare: Double?
        let decodes: [Decode]?
        let stages: [Stage]
        let final: String?
    }

    /// A rule someone taught the app, on its own line.
    ///
    /// The one free source of human labels in the whole system: a correction is
    /// a person saying, in real distribution and unprompted, that the decoder
    /// got a word wrong and what the right one was. It cannot be reconstructed
    /// afterwards from anything else on disk.
    ///
    /// These are the corrections ParrotFlow mediates — the panel, an inline
    /// instruction, `--learn`. A change made by hand in the field is `Edit`.
    fileprivate struct Correction: Encodable {
        let v: Int
        let kind: String
        let at: String
        let heard: String
        let corrected: String
        let via: String
    }

    /// A word changed by hand in the field after the dictation landed.
    ///
    /// Every one the watch sees, not only the ones the panel opens on. A
    /// misheard ordinary word — `backgrounds` for `bigrams` — is refused by
    /// the panel because both sides are words the lists know, and it is
    /// exactly the label a misheard-word stage would need. Rewords are kept
    /// too: at record time nothing can tell `hear -> say` from `drew -> few`,
    /// since real mishearings score 0.20 to 0.43 on the sound measure and
    /// unrelated words in the same slot score the same. Sound is a question
    /// for whoever reads the file.
    ///
    /// `text` is the line **as heard**, before the change, and `range` is
    /// where `heard` stands in it, in characters. A sentence with the fix
    /// already in it is worse than none: the term portrait was once scored
    /// on text after the rule had written the term in, and 4 of 4 cases
    /// flipped when scored as heard.
    ///
    /// This stores the person's own sentences. That is the point of it: a
    /// count table keeps statistics and drops the context, and the context is
    /// what a scorer needs. `docs/corrections.md` says so.
    fileprivate struct Edit: Encodable {
        let v: Int
        let kind: String
        let at: String
        let heard: String
        let corrected: String
        let text: String
        let range: [Int]
        let lang: String
        let app: String?
        /// Seconds between the dictation landing and the change.
        let after: Double
    }

    /// A place the vocabulary pass could not settle, and the answer. See
    /// `chose`.
    fileprivate struct Chose: Encodable {
        let v: Int
        let kind: String
        let at: String
        /// The vocabulary term the place was about.
        let term: String
        let kept: String
        let chose: String
        /// The sentence as it stood when the question was asked.
        let text: String
        /// Where `chose` stands in `text`, in character offsets — the same
        /// unit `Edit.range` uses, so a script reading both kinds of line does
        /// not have to know which record it is holding.
        let range: [Int]
        let lang: String
        let app: String?
        /// Seconds between the question going up and the answer.
        let after: Double
    }

    fileprivate struct ASR: Encodable {
        /// Which model produced this. Without it there is no telling a prompt
        /// regression from a model that changed under you between two runs.
        /// The repository id is all FluidAudio exposes — there is no revision
        /// to log, so none is invented.
        let model: String
        /// Which decode this came from — `first pass`, or the arm that beat
        /// it. `decodes` says what the others cost.
        let arm: String?
        let text: String
        let confidence: Float
        let duration: Double
        let processing: Double
        let words: [Word]
    }

    /// One decode of the clip. Several run on a dictation that looks short, and
    /// until this only the winner was kept — so a dictation that paid for four
    /// decodes reported one number, and an arm that failed every time was
    /// invisible rather than losing.
    fileprivate struct Decode: Encodable {
        let arm: String
        let seconds: Double
        let reached: Double?
        let taken: Bool
    }

    fileprivate struct VAD: Encodable {
        /// What the gate cost. Not `total`, which is how long the clip is:
        /// one is wall clock and the other is audio.
        let seconds: Double?
        let speech: Double
        let total: Double
        let segments: [[Double]]
    }

    /// Seconds from the hotkey press. Written by a live dictation only: a clip
    /// replayed from disk was never pressed for.
    fileprivate struct Capture: Encodable {
        /// The press itself, in wall clock and to the millisecond. `at` on the
        /// record is written when the pipeline ended and only to the second,
        /// so without this there is no zero to measure anything from.
        let at: String?
        let engine: Double?
        let firstSample: Double?
        /// Key up, seconds from the press.
        let stopped: Double?

        enum CodingKeys: String, CodingKey {
            case at, engine, stopped
            case firstSample = "first_sample"
        }
    }

    // MARK: - The timeline

    /// `logging.spans` — whether `spans.jsonl` is written.
    ///
    /// Only the file. Spans are always collected: they cost an array of about
    /// thirty small structs, and the corpus reads its `parts` and `decodes`
    /// straight off them, so a build with this off still gets the numbers in
    /// `trace.jsonl`.
    nonisolated(unsafe) static var spansEnabled = false

    static let spansFile = "spans.jsonl"

    /// Its own number. `spans.jsonl` is a new file, not a new shape of
    /// `trace.jsonl`, and borrowing that file's version would say the corpus
    /// had changed when it has not.
    static let spansVersion = 1

    /// Enough for any real dictation — about 30 — with room for a clip that
    /// puts a boundary reading on every other word.
    static let spanLimit = 400

    /// One thing the app spent wall-clock time doing.
    ///
    /// Flat, with a `parent`, rather than nested. The decode arms overlap, so
    /// they have no single place in a tree; a span finishes at a different time
    /// from its parent, so appending is simpler than reaching into a nested
    /// object; and one flat array is one query away from every question.
    ///
    /// **A span is wall-clock, never audio.** Word timings and speech segments
    /// are positions in the recording. They look the same and mean nothing
    /// alike, so they stay payload on the span that produced them — 19 word
    /// "spans" on a timeline would draw a picture that is false.
    struct Span: Encodable, Sendable {
        enum Kind: String, Encodable, Sendable {
            case load, gate, decode, stage, part, model
        }

        let id: Int
        let parent: Int?
        let name: String
        let kind: Kind
        /// Seconds from the collector's origin, and how long it took.
        let at: Double
        let dur: Double
        /// Whatever this kind of span has to say about itself. A stage says
        /// what it changed, in words — see `Trace.changeSummary`, which caps
        /// both a run and the whole note. Capped and never the transcript
        /// again: a stage already writes its text to the corpus, and repeating
        /// it here doubles the file for nothing.
        let note: String?

        enum CodingKeys: String, CodingKey { case id, parent, name, kind, at, dur, note }
    }

    /// A span that has started. Closing it is what records it.
    struct OpenSpan {
        let id: Int
        fileprivate let name: String
        fileprivate let kind: Span.Kind
        fileprivate let parent: Int?
        fileprivate let nests: Bool
        fileprivate let at: Double
        fileprivate let collector: Collector

        /// - Parameter note: what the span found out while it ran, which is
        ///   usually only knowable at the end.
        func close(_ note: String? = nil) {
            collector.close(Span(
                id: id, parent: parent, name: name, kind: kind,
                at: at, dur: max(0, collector.elapsed() - at), note: note
            ), restoring: nests)
        }
    }

    /// One dictation's timeline, one line of `spans.jsonl`.
    fileprivate struct Timeline: Encodable {
        let v: Int
        let kind: String
        let t0: String
        let wav: String
        let source: String
        let app: App?
        let lang: String?
        let spans: [Span]
        let final: String?
    }

    struct Word: Encodable, Sendable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Float
    }

    fileprivate struct Stage: Encodable {
        let name: String
        var skipCode: String?
        var skipped: String?
        /// What this stage changed, in the coordinates of the text it was
        /// handed — see `Trace.edits`. Absent when it changed nothing, which
        /// is 93.6% of the time and which `vars.changed` already says.
        var edits: [Change]?
        /// The sub-steps, taken from the timeline this stage's span parents.
        /// `vocabulary` was one number covering an exact pass, a near-miss
        /// pass, a phoneme pass and two gates; on one measured dictation 817ms
        /// of its 822 was the phoneme pass, matching nothing.
        var parts: [Part]?
        var seconds: Double?
        /// What the stage published about itself — `count`, `language`, and the
        /// `ran`/`ok`/`changed`/`ms` the pipeline derives for every stage.
        ///
        /// Worth a column of its own rather than folding into the prose: this is
        /// the file a sweep runs over, and "which transcripts did
        /// code_identifiers actually fire on" is a `jq` query when the numbers
        /// are numbers and a regex over English when they are not.
        var vars: [String: Scope.Value]?

        enum CodingKeys: String, CodingKey {
            case name
            case skipCode = "skip_reason"
            case skipped, edits, parts, seconds, vars
        }

        init(name: String, skipCode: String, skipped: String) {
            self.name = name
            self.skipCode = skipCode
            self.skipped = skipped
        }

        init(
            name: String, before: String, after: String, seconds: Double,
            vars: [String: Scope.Value]
        ) {
            self.name = name
            let changed = Trace.edits(from: before, to: after)
            self.edits = changed.isEmpty ? nil : changed
            self.seconds = seconds
            self.vars = vars.isEmpty ? nil : vars
        }
    }

    /// A sub-step of a stage, as it reaches the corpus. The same thing the
    /// timeline calls a `part`, flattened next to the stage it belongs to so a
    /// sweep can ask what one costs without reading the other file.
    fileprivate struct Part: Encodable {
        let name: String
        let seconds: Double
        let note: String?
    }
}
