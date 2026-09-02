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
    static let version = 2

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

        init(wav: String, source: Source) {
            self.wav = wav
            self.source = source
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
                text: result.text,
                confidence: result.confidence,
                duration: result.duration,
                processing: result.processingTime,
                words: Trace.words(from: result.tokenTimings ?? [])
            )
        }

        func recordVAD(speech: Double, total: Double, segments: [(Double, Double)]) {
            lock.lock(); defer { lock.unlock() }
            vad = VAD(
                speech: speech, total: total,
                segments: segments.map { [$0.0, $0.1] }
            )
        }

        /// How long the press waited, in seconds, before the engine was running
        /// and before the microphone delivered anything.
        ///
        /// Both from the press, so the difference between them is the device's
        /// own start-up. Everything before `firstSample` is speech that was
        /// said into a microphone that was not yet recording — the clips that
        /// begin mid-word have no other explanation, and until this field there
        /// was nothing on disk that could size it.
        func recordCapture(engine: Double?, firstSample: Double?) {
            lock.lock(); defer { lock.unlock() }
            capture = Capture(engine: engine, firstSample: firstSample)
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
            return Record(
                v: Trace.version, kind: Kind.dictation.rawValue,
                at: at, wav: wav, source: source.rawValue, app: app, lang: lang,
                asr: asr, vad: vad, capture: capture, stages: stages, final: final
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
    static func record<T>(
        wav: String, source: Source, app: App? = nil, beside: URL? = nil,
        body: () async throws -> T
    ) async rethrows -> T {
        let collector = Collector(wav: wav, source: source)
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
        defer { append(collector.record(at: stamp(), app: app), to: directory) }
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
    private static func append<Line: Encodable>(_ record: Line, to directory: URL?) {
        guard let directory else { return }
        let url = directory.appendingPathComponent("trace.jsonl")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)  // one object per line, so `jq -c` and friends work

        queue.async {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
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
        var words: [Word] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var confidence = Float.greatestFiniteMagnitude

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            words.append(
                Word(word: trimmed, start: start, end: end, confidence: confidence)
            )
        }

        for timing in timings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }

            // SentencePiece marks a word's first piece with `▁`; the tokenizer
            // hands some of them back already rendered as a leading space.
            if token.hasPrefix("\u{2581}") || token.hasPrefix(" ") || text.isEmpty {
                if !text.isEmpty { flush() }
                text = token.replacingOccurrences(of: "\u{2581}", with: "")
                start = timing.startTime
                confidence = timing.confidence
            } else {
                text += token
                confidence = min(confidence, timing.confidence)
            }
            end = timing.endTime
        }
        flush()
        return words
    }

    // MARK: - Shape on disk

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
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

    fileprivate struct ASR: Encodable {
        /// Which model produced this. Without it there is no telling a prompt
        /// regression from a model that changed under you between two runs.
        /// The repository id is all FluidAudio exposes — there is no revision
        /// to log, so none is invented.
        let model: String
        let text: String
        let confidence: Float
        let duration: Double
        let processing: Double
        let words: [Word]
    }

    fileprivate struct VAD: Encodable {
        let speech: Double
        let total: Double
        let segments: [[Double]]
    }

    /// Seconds from the hotkey press. Written by a live dictation only: a clip
    /// replayed from disk was never pressed for.
    fileprivate struct Capture: Encodable {
        let engine: Double?
        let firstSample: Double?

        enum CodingKeys: String, CodingKey {
            case engine
            case firstSample = "first_sample"
        }
    }

    struct Word: Encodable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Float
    }

    fileprivate struct Stage: Encodable {
        let name: String
        var skipCode: String?
        var skipped: String?
        var before: String?
        var after: String?
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
            case skipped, before, after, seconds, vars
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
            self.before = before
            self.after = after
            self.seconds = seconds
            self.vars = vars.isEmpty ? nil : vars
        }
    }
}
