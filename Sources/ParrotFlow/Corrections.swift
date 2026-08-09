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
            build: AppVariant.buildStamp, skipped: nil
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
    private static func keep(
        heard: String, term: String, clip: String?, config: Config
    ) -> Result<Kept, Refused> {
        let recordings = config.resolvedOutputDir
        let delivered = clip.flatMap { Trace.delivered(clip: $0, in: recordings) }
            ?? Trace.delivered(saying: heard, in: recordings)
        guard let delivered else {
            return .failure(Refused(reason: "no trace line for this dictation"))
        }
        guard !delivered.words.isEmpty else {
            return .failure(Refused(
                reason: "the trace line carries no word times",
                wav: delivered.wav, lang: delivered.lang
            ))
        }
        guard let span = span(of: heard, in: delivered.words) else {
            return .failure(Refused(
                reason: "\"\(heard)\" is not in the decoder's own words for this clip",
                wav: delivered.wav, lang: delivered.lang
            ))
        }

        // The duration guard. Loud, and it names the number it rejected.
        let words = renderingWords(heard).count
        let allowed = longestWord + perExtraWord * Double(max(0, words - 1))
        let length = span.end - span.start
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

        let name = VoiceStore.nextSampleName(for: term, heard: heard)
        let target = VoiceStore.samples(for: term).appendingPathComponent(name)
        do {
            try cut(from: source, start: span.start - padding, end: span.end + padding, to: target)
        } catch {
            return .failure(Refused(
                reason: "the cut failed: \(error.localizedDescription)",
                wav: delivered.wav, lang: delivered.lang
            ))
        }
        return .success(Kept(
            sample: "samples/\(term)/\(name)", wav: delivered.wav, lang: delivered.lang,
            start: span.start, end: span.end
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

        var lastSeen: [String: Date] = [:]
        for observation in VoiceStore.observations()
        where observation.term.caseInsensitiveCompare(term) == .orderedSame {
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
