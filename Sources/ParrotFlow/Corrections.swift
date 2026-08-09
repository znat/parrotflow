import AVFoundation
import Foundation

/// What happens when somebody corrects a word: the rule, the observation, and
/// the audio.
///
/// Until now a correction wrote one line of YAML and threw the rest away. That
/// is the expensive half being discarded: a correction is a person saying, in
/// their own voice and unprompted, that a term was said *here* and the decoder
/// wrote *that* instead. It is a labelled recording, free, and there is no
/// other source of one.
///
/// Why the audio is worth keeping at all, in one number: `Matthieu` separates
/// its correct utterances from its wrong ones at AUC 0.556 on 2 recordings —
/// chance — and at 1.000 on 11. Same rows, same hold-out, only the recordings
/// changed. A thin bank is a shortage of clips, not a verdict on the term, and
/// this is what makes clips arrive without anybody being asked for them.
///
/// **One route to the audio, not two.** The word times come from
/// `trace.jsonl`, joined to the clip by its filename. The alternative was to
/// carry the decoder's timings in memory from `Transcriber` to whichever panel
/// the person eventually saves, and it fails on the case that matters: `--learn`
/// is a separate process that never saw the dictation, so it would need the
/// file route anyway and the app would have grown a second mechanism for one
/// job. The trace is written for every dictation, before any panel can open,
/// and PR 5 moves mining onto the same read.
enum Corrections {

    /// A span longer than this is not one word being said.
    ///
    /// Measured, not guessed: over 60 real correction spans in the archive the
    /// median is 0.64s and the 90th percentile 0.88s, and 2 of the 60 run past
    /// 2s with the worst at 6.4s — a word timing that swallowed the pause after
    /// it. Cutting one of those files a recording of a name plus a silence
    /// under that name, which is exactly the bad clip Part 1 §7 says widens a
    /// term's cloud and disarms its veto.
    static let longestWord: Double = 2.0

    /// And this much more for each word after the first, because a rendering
    /// can be two words — `super base`, `red crawl`.
    static let perExtraWord: Double = 1.0

    /// The word's edges are where it is least clear, so keep a little either
    /// side. The same 0.05s `scripts/mine-pronunciations.py` cuts with, so a
    /// mined sample and a corrected one are the same kind of object.
    static let padding: Double = 0.05

    /// What was written down, for the caller to log.
    struct Outcome {
        /// The vocabulary term this was promoted under, if it was one.
        var term: String?
        /// How the rendering now stands in `vocabulary.yaml`.
        var seen: Int?
        /// The sample written, relative to `voice/`.
        var sample: String?
        /// Why there is no sample. Nil when there is one, or when the
        /// correction was not about a vocabulary term at all.
        var skipped: String?
        /// Samples the per-term cap removed, and why each one went.
        var capped: [(file: String, why: String)] = []
        /// Renderings the seen-once rule dropped.
        var pruned: [String] = []
        /// Set when this was a revert rather than a correction — the term was
        /// taken back, no rule was written, and the clip is a negative.
        var revert: Revert?
    }

    /// What a revert did.
    struct Revert {
        /// The ordinary word the term was taken back to.
        var word: String
        /// What was blamed for the term firing, and what was done about it.
        var blame: Blame
        /// The pair's counts in `collides_with:` afterwards.
        var reverted: Int
        var clips: Int
    }

    /// What caused the term to be written where it was not said.
    ///
    /// Only two things can do it, and only one of them leaves a trace anything
    /// can act on. An exact rule — a rendering in the term's
    /// `pronunciations:`, which `Config.vocabularyRules` turns into a
    /// replacement — fires on that spelling every time, so if the word the
    /// speaker meant is registered as a rendering of the term, that rule is
    /// what fired. Otherwise the acoustic pass proposed it from the audio, and
    /// there is nothing in any file to blame.
    enum Blame: Equatable {
        /// A rendering fired, and its `seen:` count went down to this.
        case rendering(String, seen: Int)
        /// A rendering fired, stood at one sighting from one correction, and
        /// is now gone: one sighting against one revert leaves nothing.
        case dropped(String)
        /// A rendering fired and could not be counted down — a legacy `heard:`
        /// list, or an entry that was never counted. It is left alone.
        case uncounted(String)
        /// A rule in `config.yaml` maps the word to the term. A person wrote
        /// that by hand, so it is named and not touched.
        case handWritten(String)
        /// Nothing in the data caused it. The acoustic pass proposed the term
        /// from the audio, and the negative clip is the whole answer.
        case nothing
    }

    /// Learn that `heard` should have been `corrected`.
    ///
    /// Two shapes, decided by whether `corrected` names a term in
    /// `vocabulary.yaml`:
    ///
    /// - **A term.** The rendering is promoted into `vocabulary.yaml` under
    ///   that term's `pronunciations:`, with `from: correction` and a `seen:`
    ///   count, and the audio is cut. `Config.vocabularyRules` turns that entry
    ///   into the same exact replacement `config.yaml` would have carried, so
    ///   the correction takes effect exactly as before — it is now recorded in
    ///   the file that owns learnt data and knows where each entry came from.
    ///   It is also the file `--forget` can reach, which `config.yaml` was not.
    /// - **A term the other way round.** `Praisy` → "praise" is a *revert*: the
    ///   term was written where an ordinary word was said. No rule is written
    ///   anywhere, the rendering that fired is counted down, and the audio is
    ///   kept as a negative. See `revert`.
    /// - **Anything else.** `teh` → `the` is not a name and has no audio worth
    ///   keeping. It goes to `transcription.replacements` in `config.yaml`,
    ///   which is what has always happened.
    ///
    /// - Parameter clip: the dictation being corrected, when the caller has it.
    ///   Without it the newest dictation whose text contains `heard` is used.
    @discardableResult
    static func learn(
        heard: String, corrected: String, via: String, clip: String? = nil
    ) throws -> Outcome {
        let config = try ConfigStore.load()
        let term = config.vocabulary.terms.keys.first {
            $0.caseInsensitiveCompare(corrected) == .orderedSame
        }

        // Asked before the forward path, because the two are decided by the
        // same two lookups and only one of them can be true.
        if let taken = ConfigWriter.revertedTerm(
            heard: heard, corrected: corrected, in: config.vocabulary
        ) {
            return try revert(
                term: taken, to: corrected, via: via, clip: clip, config: config
            )
        }

        guard let term else {
            try ConfigWriter.addReplacement(heard: heard, corrected: corrected)
            Trace.correction(heard: heard, corrected: corrected, via: via, clip: clip)
            return Outcome()
        }

        var outcome = Outcome(term: term)
        outcome.seen = try ConfigWriter.addPronunciation(term: term, heard: heard)
        Trace.correction(heard: heard, corrected: corrected, via: via, clip: clip)

        // The rendering is recorded whether or not the audio can be, so a
        // correction is never lost to a missing clip. `skipped` says which
        // happened, and it is on the row rather than only in the log because
        // the log truncates at 1 MB and this rate is worth counting later.
        var observation = VoiceStore.Observation(
            at: stamp(), term: term, heard: heard, from: "correction",
            score: nil, mic: Recorder.inputDeviceName, span: nil,
            sample: nil, wav: nil, lang: nil,
            build: AppVariant.buildStamp, skipped: nil,
            polarity: VoiceStore.Polarity.positive.rawValue
        )

        switch keep(heard: heard, term: term, clip: clip, config: config) {
        case .success(let kept):
            observation.span = [kept.start, kept.end]
            observation.sample = kept.sample
            observation.wav = kept.wav
            observation.lang = kept.lang
            outcome.sample = kept.sample
        case .failure(let why):
            observation.skipped = why.reason
            observation.wav = why.wav
            observation.lang = why.lang
            outcome.skipped = why.reason
        }

        try VoiceStore.append(observation)
        outcome.capped = VoiceStore.enforceCap(on: term)
        outcome.pruned = try prune(term: term)
        return outcome
    }

    // MARK: - Taking a term back

    /// The speaker says the term should not have fired here.
    ///
    /// Three things happen, and writing a replacement rule is not one of them.
    /// A rule would rewrite every `Praisy` into "praise" from then on, correct
    /// ones included — see `ConfigWriter.addReplacement`, which refuses that
    /// shape whoever asks.
    ///
    /// 1. **Confidence in whatever fired goes down.** If the ordinary word is
    ///    registered as a rendering of the term, that exact rule is what wrote
    ///    it, and its `seen:` count goes down by one. Nothing else can be
    ///    blamed: the only other thing that writes a term where it was not said
    ///    is the acoustic pass, and it proposes from the audio, so no file
    ///    holds anything to take back.
    /// 2. **The pair is recorded** under the term as `collides_with:`, which is
    ///    never matched and never substituted. It says which two things to
    ///    compare later, and it is keyed on the pair — "praise" argues with
    ///    `Praisy` and means nothing to `Supabase`.
    /// 3. **The audio is kept as a negative**, in `voice/negatives/<Term>/`.
    ///
    /// **They happen in the reverse of that order.** There is no transaction
    /// across `vocabulary.yaml` and `voice/`, so the writes are ordered by what
    /// a retry costs, and the count comes down last — it is the only one of the
    /// three that cannot be repeated safely.
    ///
    /// **No sample is deleted.** Nothing in `samples/` caused this: the samples
    /// feed the acoustic veto, not the rule that fired, and experiment 6a
    /// (PR #82) showed a bad clip cannot be picked out of a bank from one
    /// revert — the obvious geometric signal points at legitimate recordings
    /// instead.
    private static func revert(
        term: String, to word: String, via: String, clip: String?, config: Config
    ) throws -> Outcome {
        var outcome = Outcome(term: term)
        Trace.correction(heard: term, corrected: word, via: via, clip: clip)

        // What fired. The rendering list is the only thing that can be blamed,
        // and it is read from the loaded model rather than the file so a legacy
        // `heard:` list counts too — `Config.Term.heard` merges both keys.
        //
        // Only *named* here. Taking the count down is the last thing this
        // function does — see below.
        let entry = config.vocabulary.terms.first {
            $0.key.caseInsensitiveCompare(term) == .orderedSame
        }?.value
        let rendering = entry?.heard.first { $0.caseInsensitiveCompare(word) == .orderedSame }
        let handWritten = config.transcription.rules.first {
            $0.source.caseInsensitiveCompare(word) == .orderedSame
                && $0.replacement.caseInsensitiveCompare(term) == .orderedSame
        }

        // The clip is cut against the *ordinary* word, not the term. The word
        // times in `trace.jsonl` come from `asr.words`, which is the decoder's
        // own output before any vocabulary stage runs — so the word sitting at
        // the span is "praise", the thing that was actually said. The term is
        // tried second, for the case where the decoder wrote the name itself
        // and no rule was involved at all.
        var observation = VoiceStore.Observation(
            at: stamp(), term: term, heard: word, from: "correction",
            score: nil, mic: Recorder.inputDeviceName, span: nil,
            sample: nil, wav: nil, lang: nil,
            build: AppVariant.buildStamp, skipped: nil,
            polarity: VoiceStore.Polarity.negative.rawValue
        )
        var kept = 0
        switch keep(
            heard: word, term: term, clip: clip, config: config,
            polarity: .negative, saying: term
        ) {
        case .success(let cut):
            observation.span = [cut.start, cut.end]
            observation.sample = cut.sample
            observation.wav = cut.wav
            observation.lang = cut.lang
            outcome.sample = cut.sample
            kept = 1
        case .failure(let why):
            observation.skipped = why.reason
            observation.wav = why.wav
            observation.lang = why.lang
            outcome.skipped = why.reason
        }
        try VoiceStore.append(observation)
        outcome.capped = VoiceStore.enforceCap(on: term, .negative)

        let counts = try ConfigWriter.recordCollision(term: term, word: word, clips: kept)

        // The count comes down last, because it is the only write here that
        // cannot be repeated safely. There is no transaction across two files,
        // so the writes are ordered by what a retry costs: an observation is a
        // row in an append-only file and a duplicate is visible and harmless; a
        // collision is a counter and one extra is recoverable; a `seen:` taken
        // down twice can delete a rendering that should have stood at one, and
        // nothing puts it back. Ordered this way, a failure anywhere above
        // leaves the count untouched and the retry is clean.
        var blame = Blame.nothing
        if let rendering {
            switch try ConfigWriter.discountPronunciation(term: term, heard: rendering) {
            case .reduced(let seen): blame = .rendering(rendering, seen: seen)
            case .dropped: blame = .dropped(rendering)
            case .uncounted, .notFound: blame = .uncounted(rendering)
            }
        } else if let rule = handWritten {
            // A rule somebody wrote into `config.yaml` by hand. Named, never
            // edited: that file is written by a person and read by the app, and
            // silently rewriting a line they typed is not this code's business.
            blame = .handWritten(rule.source)
        }

        outcome.revert = Revert(
            word: word, blame: blame, reverted: counts.reverted, clips: counts.clips
        )
        return outcome
    }

    /// What a revert did, in words, for whoever has to say it out loud.
    ///
    /// One place rather than two: the terminal prints these and the app logs
    /// them, and a revert that reads differently depending on where it happened
    /// is a revert nobody can compare afterwards.
    static func said(about revert: Revert?, term: String) -> [String] {
        guard let revert else { return [] }
        var lines = [
            "no rule written — a rule here would rewrite every \(term)"
                + " into \"\(revert.word)\"",
        ]
        switch revert.blame {
        case .rendering(let heard, let seen):
            lines.append("\(term): \"\(heard)\" fired and is now seen \(seen) time(s)")
        case .dropped(let heard):
            lines.append("\(term): dropped \"\(heard)\" — one sighting, one revert,"
                + " nothing left")
        case .uncounted(let heard):
            lines.append("\(term): \"\(heard)\" fired and was never counted,"
                + " so there is nothing to count down — left as it is")
        case .handWritten(let source):
            lines.append("\(term): a rule you wrote in config.yaml maps"
                + " \"\(source)\" to it — left alone, edit it yourself")
        case .nothing:
            lines.append("\(term): nothing in the files fired,"
                + " so the acoustic pass proposed it and there is nothing to blame")
        }
        lines.append("collides_with \"\(revert.word)\": reverted \(revert.reverted) time(s),"
            + " \(revert.clips) clip(s)")
        return lines
    }

    // MARK: - Cutting the audio out

    private struct Kept {
        let sample: String
        let wav: String
        let lang: String?
        let start: Double
        let end: Double
    }

    private struct Refused: Error {
        let reason: String
        var wav: String?
        var lang: String?
    }

    /// Finds the rendering in the dictation's word times and cuts it out.
    ///
    /// - Parameter polarity: which bank the clip goes into. A correction's clip
    ///   is the term; a revert's clip is the ordinary word the term was written
    ///   over, and the two must never share a directory — see `VoiceStore`.
    /// - Parameter saying: the text to find the dictation by when no clip was
    ///   named. Defaults to `heard`, which is what the delivered text holds
    ///   after a correction. A revert needs the term instead: the delivered
    ///   text is the sentence with the term already written into it, and the
    ///   ordinary word is exactly what is no longer in it.
    /// - Parameter alternate: a second spelling to look for in the word times.
    ///   A revert passes the term, for the clip where the decoder wrote the
    ///   name itself and no rule was involved.
    private static func keep(
        heard: String, term: String, clip: String?, config: Config,
        polarity: VoiceStore.Polarity = .positive, saying: String? = nil
    ) -> Result<Kept, Refused> {
        let recordings = config.resolvedOutputDir
        let delivered = clip.flatMap { Trace.delivered(clip: $0, in: recordings) }
            ?? Trace.delivered(saying: saying ?? heard, in: recordings)
        guard let delivered else {
            return .failure(Refused(reason: "no trace line for this dictation"))
        }
        guard !delivered.words.isEmpty else {
            return .failure(Refused(
                reason: "the trace line carries no word times",
                wav: delivered.wav, lang: delivered.lang
            ))
        }
        // Whichever spelling the decoder actually wrote, so the duration guard
        // below counts the words it found rather than the words it looked for.
        let alternates = polarity == .negative ? [heard, term] : [heard]
        guard let found = alternates.lazy.compactMap({ spelling in
            Self.span(of: spelling, in: delivered.words).map { (spelling: spelling, at: $0) }
        }).first else {
            return .failure(Refused(
                reason: "\"\(heard)\" is not in the decoder's own words for this clip",
                wav: delivered.wav, lang: delivered.lang
            ))
        }
        let at = found.at

        // The duration guard. Loud, and it names the number it rejected.
        let words = renderingWords(found.spelling).count
        let allowed = longestWord + perExtraWord * Double(max(0, words - 1))
        let length = at.end - at.start
        guard length > 0, length <= allowed else {
            return .failure(Refused(
                reason: String(
                    format: "the span is %.2fs, over the %.2fs allowed for %d word(s)",
                    length, allowed, words
                ),
                wav: delivered.wav, lang: delivered.lang
            ))
        }

        let source = recordings.appendingPathComponent(delivered.wav)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(Refused(
                reason: "the clip is no longer on disk",
                wav: delivered.wav, lang: delivered.lang
            ))
        }

        let name = VoiceStore.nextSampleName(for: term, heard: heard, polarity)
        let target = VoiceStore.clips(for: term, polarity).appendingPathComponent(name)
        do {
            try cut(from: source, start: at.start - padding, end: at.end + padding, to: target)
        } catch {
            return .failure(Refused(
                reason: "the cut failed: \(error.localizedDescription)",
                wav: delivered.wav, lang: delivered.lang
            ))
        }
        return .success(Kept(
            sample: "\(polarity.folder)/\(term)/\(name)",
            wav: delivered.wav, lang: delivered.lang,
            start: at.start, end: at.end
        ))
    }

    /// Where a rendering sits in the decoder's own words.
    ///
    /// Matched as a sequence, because a rendering can be more than one word —
    /// `Supabase` comes back as "super base" and `Redcrawl` as "red crawl" more
    /// often than not. Punctuation is stripped from both sides: the decoder
    /// writes "praise." at the end of a sentence and the person correcting it
    /// types "praise".
    static func span(of heard: String, in words: [Trace.Word]) -> (start: Double, end: Double)? {
        let wanted = renderingWords(heard)
        guard !wanted.isEmpty, words.count >= wanted.count else { return nil }
        let bare = words.map { plain($0.word) }
        // The last match, not the first. When a word occurs twice the later one
        // is the one still on screen when somebody corrects it, and taking the
        // first would cut a different utterance than the one being talked about.
        for start in stride(from: bare.count - wanted.count, through: 0, by: -1)
        where Array(bare[start..<(start + wanted.count)]) == wanted {
            return (words[start].start, words[start + wanted.count - 1].end)
        }
        return nil
    }

    private static func renderingWords(_ heard: String) -> [String] {
        heard.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { plain(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// A word with nothing on it but its letters, digits and apostrophes,
    /// folded to lower case.
    private static func plain(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    /// Writes `[start, end]` of `source` into `target`.
    ///
    /// Through `AVAudioFile` rather than by slicing the PCM by hand: the
    /// recorder's format is whatever the input device gave it, and a hand-rolled
    /// header that is wrong about the sample rate produces a file that plays and
    /// scores as a different sound.
    static func cut(from source: URL, start: Double, end: Double, to target: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let rate = format.sampleRate

        let first = max(0, AVAudioFramePosition(start * rate))
        let last = min(input.length, AVAudioFramePosition(end * rate))
        guard last > first else { throw CutError.emptySpan }

        let count = AVAudioFrameCount(last - first)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw CutError.emptySpan
        }
        input.framePosition = first
        try input.read(into: buffer, frameCount: count)

        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let output = try AVAudioFile(
            forWriting: target, settings: input.fileFormat.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        try output.write(from: buffer)
    }

    enum CutError: LocalizedError {
        case emptySpan

        var errorDescription: String? {
            switch self {
            case .emptySpan: return "the span is empty once it is clipped to the recording"
            }
        }
    }

    // MARK: - Dropping a rendering seen once and never again

    /// How long a rendering seen exactly once has to prove itself.
    ///
    /// A rendering the decoder produced once is as likely to be a one-off
    /// mis-decode as a way this person says the word, and the two are
    /// indistinguishable on the day. Repetition is what tells them apart, so the
    /// rule is time and not a count: a month of dictation without it happening
    /// again says it was noise. `heard:` lists only ever grow, and this is the
    /// only thing in the app that takes an entry back out on its own.
    static let proveWithin: TimeInterval = 30 * 24 * 60 * 60

    /// Removes this term's renderings that were seen once, long ago, and never
    /// again. Returns what went, so the caller can say it out loud.
    ///
    /// Only ever removes a rendering `from: correction` with `seen: 1`. A mined
    /// or legacy entry has no honest first-seen date — `seen: 0` means "never
    /// counted", which is every entry written before the key existed — and
    /// deleting on a date nobody recorded is how a prune eats correct data.
    private static func prune(term: String) throws -> [String] {
        let vocabulary = ConfigStore.loadVocabulary()
        guard let entry = vocabulary.terms.first(where: {
            $0.key.caseInsensitiveCompare(term) == .orderedSame
        })?.value else { return [] }

        // Positives only. A negative row says the term was *not* said, and it
        // carries the ordinary word under the same `heard` key — so counting it
        // here would let a revert of "praise" keep the rendering "praise"
        // alive, which is the opposite of what the revert meant.
        var lastSeen: [String: Date] = [:]
        for observation in VoiceStore.observations()
        where observation.kind == .positive
            && observation.term.caseInsensitiveCompare(term) == .orderedSame {
            guard let at = date(observation.at) else { continue }
            let key = plain(observation.heard)
            lastSeen[key] = max(lastSeen[key] ?? at, at)
        }

        var dropped: [String] = []
        for rendering in entry.pronunciations
        where rendering.seen == 1 && rendering.from == .correction {
            guard let at = lastSeen[plain(rendering.heard)],
                  Date().timeIntervalSince(at) > proveWithin
            else { continue }
            if try ConfigWriter.dropPronunciation(term: term, heard: rendering.heard) {
                dropped.append(rendering.heard)
            }
        }
        return dropped
    }

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func date(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let at = full.date(from: text) { return at }
        // What mining writes: the clip's own name, which has no zone on it.
        let bare = ISO8601DateFormatter()
        bare.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime,
                              .withDashSeparatorInDate]
        bare.timeZone = TimeZone.current
        return bare.date(from: text)
    }
}
