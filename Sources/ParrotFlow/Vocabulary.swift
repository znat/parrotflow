import FluidAudio
import Foundation

/// Writes the names in `vocabulary:` into a transcript that got them wrong,
/// by matching sound rather than spelling.
///
/// This runs inside transcription, not in the pipeline. It needs the audio and
/// the token timings the decoder produced, and a pipeline stage only ever sees
/// text — once `numbers` has turned "nineteen" into "19" the timings no longer
/// line up with the words.
///
/// ## The settings, and why they are not the defaults
///
/// FluidAudio proposes a replacement two ways. The first matches the decoded
/// words against the vocabulary by edit distance, gated by `minSimilarity`.
/// The second — the spotter-anchored rescue — replaces a span because the CTC
/// keyword spotter heard the term there, and it ignores similarity entirely.
///
/// On stock settings the rescue is on and its own floors are disabled, which
/// is why an earlier attempt at this was removed: 370 of 386 clips containing
/// none of the vocabulary came out altered, and sweeping `minSimilarity` to
/// 0.90 did nothing because it was gating the wrong path. FluidAudio's #702
/// and #724 notes say the same thing — the rescue is the dominant source of
/// short-keyword over-firing, and it only runs at all for vocabularies of ten
/// terms or fewer, which is every vocabulary written here.
///
/// So the rescue is off and the short-term boost is tapered. Measured over the
/// same 386 clips: 10 altered at `minSimilarity` 0.65, 4 at 0.75, 0 at 0.85.
/// The two wrong fires at 0.65 are names that sound like real words, which is
/// what the per-term floor in `vocabulary.terms` is for.
@available(macOS 14, *)
actor Vocabulary {

    static let shared = Vocabulary()

    /// Loading the models is a ~98 MB download and several seconds, so the
    /// whole apparatus is kept and only rebuilt when the terms change.
    private var loadedFor: [String] = []
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var context: CustomVocabularyContext?

    /// FluidAudio's recommended short-vocabulary opt-ins, from the #702 note.
    private static let rescorerConfig = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        shortTermCbwTaperExponent: 2.0,
        spotterRescueEnabled: false
    )

    /// True when there is something to do, so the caller can skip the work of
    /// gathering audio for a config that asked for none of this.
    static func wanted(_ config: Config) -> Bool {
        config.vocabulary.acoustic && !config.vocabularyTerms.isEmpty
    }

    /// Downloads and builds what is needed, or reuses it. Reports progress so
    /// the first run does not look like a hang.
    func prepare(
        config: Config, progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let terms = config.vocabularyTerms
        let signature = terms.map { "\($0.text):\($0.minSimilarity)" }
        guard signature != loadedFor || rescorer == nil else { return }

        progress?("vocabulary model")
        let models = try await CtcModels.downloadAndLoad()
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: directory)

        // Pre-tokenising is what makes the spotter fire at all. A term built
        // from text alone carries no CTC token ids and is skipped in silence.
        let built = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else {
                Log.write("vocabulary: \"\(term.text)\" tokenises to nothing; skipped")
                return nil
            }
            return CustomVocabularyTerm(
                text: term.text, ctcTokenIds: ids, minSimilarity: term.minSimilarity
            )
        }
        guard !built.isEmpty else {
            loadedFor = signature
            return
        }

        let context = CustomVocabularyContext(terms: built)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        self.rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context,
            config: Self.rescorerConfig, ctcModelDirectory: directory
        )
        self.spotter = spotter
        self.context = context
        self.loadedFor = signature
        Log.write("vocabulary: \(built.count) terms — \(built.map(\.text).joined(separator: ", "))")
    }

    /// What one pass did, for the pipeline to read. `changes` is
    /// `heard -> written`, joined by `; ` — the same shape `replacements`
    /// publishes, so a judge stage can read either without knowing which
    /// proposed the substitution.
    struct Outcome: Sendable {
        let text: String
        let count: Int
        let changes: String

        static func unchanged(_ text: String) -> Outcome {
            Outcome(text: text, count: 0, changes: "")
        }
    }

    /// The transcript with any vocabulary term the decoder missed written in.
    ///
    /// Returns the text unchanged on every failure. A name that stays misheard
    /// is a worse transcript; a dictation that does not arrive is no transcript.
    func apply(
        to text: String, samples: [Float], tokenTimings: [TokenTiming], config: Config
    ) async -> Outcome {
        guard let rescorer, let spotter, let context, !tokenTimings.isEmpty else {
            return .unchanged(text)
        }

        do {
            let spotted = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: context, minScore: nil
            )
            guard !spotted.logProbs.isEmpty else { return .unchanged(text) }

            let result = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count).cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: config.vocabulary.minSimilarity
            )
            guard result.wasModified else { return .unchanged(text) }

            // Every replacement, named. This is the stage most likely to be
            // blamed for a sentence nobody recognises, and the log is where
            // that gets settled.
            var made: [String] = []
            for change in result.replacements where change.shouldReplace {
                Log.write(
                    "vocabulary: \"\(change.originalWord)\" -> "
                        + "\"\(change.replacementWord ?? "")\" (\(change.reason))"
                )
                // The acoustic scores travel with the pair. They are the one
                // piece of evidence a judge reading the sentence cannot get
                // for itself, and they are independent of it: how confidently
                // the decoder heard each spelling, rather than which one fits.
                made.append(String(
                    format: "%@ -> %@ @ %.2f/%.2f",
                    change.originalWord, change.replacementWord ?? "",
                    change.originalScore, change.replacementScore ?? 0
                ))
            }
            return Outcome(
                text: Self.restorePunctuation(from: text, to: result.text),
                count: made.count,
                changes: made.joined(separator: "; ")
            )
        } catch {
            Log.write("vocabulary: \(error.localizedDescription); left as decoded")
            return .unchanged(text)
        }
    }

    /// Puts back the trailing punctuation a replacement drops.
    ///
    /// The rescorer replaces the word and not what followed it, so "on Olama?"
    /// comes back as "on Ollama" and the question mark is gone. Measured on the
    /// archive: it happened to 4 of the 8 substitutions at the shipped setting.
    /// Only trailing marks on words that changed are restored, and only when
    /// the two texts still have the same number of words — anything else is a
    /// rewrite this should not be second-guessing.
    static func restorePunctuation(from original: String, to rescored: String) -> String {
        let before = original.split(separator: " ", omittingEmptySubsequences: false)
        let after = rescored.split(separator: " ", omittingEmptySubsequences: false)
        guard before.count == after.count else { return rescored }

        let marks = CharacterSet(charactersIn: ".,?!:;")
        return zip(before, after).map { was, now -> String in
            guard was != now, !now.isEmpty else { return String(now) }
            let tail = String(was.reversed().prefix {
                $0.unicodeScalars.allSatisfy(marks.contains)
            }.reversed())
            guard !tail.isEmpty,
                  !now.unicodeScalars.contains(where: marks.contains)
            else { return String(now) }
            return now + tail
        }.joined(separator: " ")
    }
}
