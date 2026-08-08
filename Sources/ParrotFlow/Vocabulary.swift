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

    /// CTC token count per term, kept from `prepare` so `apply` can undo the
    /// vocabulary bonus. The rescorer reports the term's score with the boost
    /// already in it, and the decoded word's without — comparing the two as
    /// printed says the audio preferred the term when often it did not.
    private var tokenCounts: [String: Int] = [:]

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
        // The pronunciations are part of what is loaded, so a `heard:` list
        // that changed has to rebuild the context like a floor does.
        let signature = terms.map { "\($0.text):\($0.minSimilarity)" }
            + config.vocabulary.terms.sorted { $0.key < $1.key }.flatMap { name, entry in
                entry.heard.map { "\(name)~\($0)" }
            }
        guard signature != loadedFor || rescorer == nil else { return }

        progress?("vocabulary model")
        let models = try await CtcModels.downloadAndLoad()
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: directory)

        // Pre-tokenising is what makes the spotter fire at all. A term built
        // from text alone carries no CTC token ids and is skipped in silence.
        var counts: [String: Int] = [:]
        let built = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else {
                Log.write("vocabulary: \"\(term.text)\" tokenises to nothing; skipped")
                return nil
            }
            counts[term.text] = ids.count
            return CustomVocabularyTerm(
                text: term.text, ctcTokenIds: ids, minSimilarity: term.minSimilarity
            )
        }
        self.tokenCounts = counts

        // Every rendering in a `heard:` list, registered as a *pronunciation*
        // of its term rather than as a spelling to substitute.
        //
        // `CustomVocabularyTerm` takes its CTC token ids explicitly, and
        // nothing requires them to be the tokenisation of `text`. So `Vercel`
        // goes in a second time carrying the tokens of "Versailles", and the
        // spotter searches the audio for that sound and reports the term.
        //
        // The table already holds this: 35 renderings the decoder actually
        // produced, spent until now on blind text substitution. As rules they
        // rewrite every "Versailles" including the palace. As pronunciations
        // they fire only where the audio agrees, and on one clip here the two
        // Versailles separate by about a nat.
        //
        // `minSimilarity` is set past 1 so the rescorer never picks these as
        // candidates — it compares spellings, and these carry the canonical
        // spelling, so they would only duplicate the entry above. The spotter
        // does not consult it, which is the whole point.
        var pronunciations: [CustomVocabularyTerm] = []
        for (name, entry) in config.vocabulary.terms.sorted(by: { $0.key < $1.key }) {
            for rendering in entry.heard {
                let ids = tokenizer.encode(rendering)
                guard !ids.isEmpty, name.count >= 5 else { continue }
                pronunciations.append(CustomVocabularyTerm(
                    text: name, ctcTokenIds: ids, minSimilarity: 1.01
                ))
            }
        }
        if !pronunciations.isEmpty {
            Log.write("vocabulary: \(pronunciations.count) pronunciation(s) from `heard:` lists")
        }

        guard !built.isEmpty || !pronunciations.isEmpty else {
            loadedFor = signature
            return
        }

        let context = CustomVocabularyContext(terms: built + pronunciations)
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

    /// One term the pass found, and what it decided to do about it.
    ///
    /// `nth` is the occurrence of `heard` in the published text, counting from
    /// zero, and it is how a later stage locates the word. Not a character
    /// offset: Swift counts graphemes, Python counts code points, and a stage
    /// boundary is the wrong place to make those agree. Not a search for the
    /// *term* either — that is what `menu.py` used to do, and two proposals
    /// sharing one target collided, which deleted the reading the speaker
    /// actually said.
    struct Proposal: Sendable {
        let heard: String
        let term: String
        let nth: Int
        /// The decoded word's CTC score. Raw.
        let heardScore: Float
        /// The term's CTC score with the vocabulary bonus removed, so the two
        /// numbers above and below mean the same thing.
        let termScore: Float
        /// The bonus that was taken off. Kept so the log can show its work.
        let bonus: Float
        /// False when only a judge should decide — see `autoApplies`.
        let applied: Bool
    }

    /// What one pass did, for the pipeline to read.
    ///
    /// `changes` stays `heard -> written @ a/b`, joined by `; `, because that
    /// is what `replacements` publishes and what every existing stage reads.
    /// `proposals` is the same information without the ambiguity, for a stage
    /// that needs to know *where*.
    struct Outcome: Sendable {
        let text: String
        let count: Int
        let changes: String
        let proposals: [Proposal]

        static func unchanged(_ text: String) -> Outcome {
            Outcome(text: text, count: 0, changes: "", proposals: [])
        }

        /// `proposals` as JSON, for a transform reading `ctx["vars"]`.
        var proposalsJSON: String {
            let items = proposals.map { p in
                let fields = [
                    "\"heard\":\"\(Self.escaped(p.heard))\"",
                    "\"term\":\"\(Self.escaped(p.term))\"",
                    "\"nth\":\(p.nth)",
                    String(format: "\"heard_score\":%.2f", p.heardScore),
                    String(format: "\"term_score\":%.2f", p.termScore),
                    String(format: "\"bonus\":%.2f", p.bonus),
                    "\"applied\":\(p.applied)",
                ]
                return "{" + fields.joined(separator: ",") + "}"
            }
            return "[" + items.joined(separator: ",") + "]"
        }

        private static func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
    }

    /// FluidAudio's own metric, so a span this file offers is scored the way
    /// the span it came from was. Normalised Levenshtein on the glued, letters
    /// only form, times the square root of the length ratio — the penalty is
    /// what stops a long run of words matching a short term on its prefix.
    static func gluedSimilarity(_ phrase: String, _ term: String) -> Float {
        let glue = { (s: String) in
            String(s.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let a = Array(glue(phrase)), b = Array(glue(term))
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                current.append(min(
                    current[j - 1] + 1, previous[j] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                ))
            }
            previous = current
        }
        let base = 1 - Float(previous[b.count]) / Float(max(a.count, b.count))
        let ratio = Float(min(a.count, b.count)) / Float(max(a.count, b.count))
        return base * sqrt(ratio)
    }

    /// How generous to be about a wider span than the rescorer picked.
    ///
    /// Below FluidAudio's own floors on purpose. These are readings offered to
    /// a judge, not substitutions, and the case they exist for scores badly by
    /// construction: `Praisy` decoded as "praise he" glues to "praisehe",
    /// which is 0.54 after the length penalty and so was refused. The one-word
    /// span inside it scored 0.83 and won outright, leaving "he" stranded in
    /// every reading on the menu.
    static let widerSpanFloor: Float = 0.45

    /// Words with the times they were spoken at, and where they sit in the
    /// transcript. Rebuilt here because FluidAudio's own `buildWordTimings` is
    /// internal to that module. A token beginning with a space or `▁` starts a
    /// new word, which is the SentencePiece convention Parakeet emits.
    static func words(
        from timings: [TokenTiming], in text: String
    ) -> [(range: Range<String.Index>, start: Double, end: Double)] {
        var built: [(text: String, start: Double, end: Double)] = []
        for timing in timings {
            let token = timing.token
            let starts = token.hasPrefix(" ") || token.hasPrefix("▁")
            let bare = token.replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if starts || built.isEmpty {
                guard !bare.isEmpty else { continue }
                built.append((bare, timing.startTime, timing.endTime))
            } else {
                built[built.count - 1].text += bare
                built[built.count - 1].end = timing.endTime
            }
        }

        // Located left to right. The words came out of this text, so each is
        // in it, and a cursor keeps repeats in the order they were spoken.
        var out: [(Range<String.Index>, Double, Double)] = []
        var cursor = text.startIndex
        for word in built where !word.text.isEmpty {
            guard let range = text.range(of: word.text, range: cursor..<text.endIndex) else {
                continue
            }
            out.append((range, word.start, word.end))
            cursor = range.upperBound
        }
        return out
    }

    /// Words too ordinary to be a name the decoder mangled.
    ///
    /// The spotter scores every term against every span, so a preposition gets
    /// a hit like anything else — `Claude` landed on "on" at -4.84 in one clip,
    /// above the real `Vercel` at -5.28. Score alone does not separate those;
    /// what the decoder wrote there does.
    static let ordinary: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "then", "than", "as",
        "in", "on", "at", "to", "for", "of", "with", "by", "from", "up", "down",
        "out", "about", "into", "over", "after", "before", "between", "under",
        "is", "are", "was", "were", "be", "been", "being", "am",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us",
        "this", "that", "these", "those", "there", "here", "what", "which",
        "not", "no", "yes", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "should", "my", "your", "our", "their",
    ]

    /// How good an acoustic hit has to be before it is worth a menu line.
    /// Tunable while this is being measured — see `--boost-eval`.
    /// How many readings one term may contribute to a menu. The cap is the
    /// point: recall wants every plausible span offered, and a person reading
    /// a lettered list wants a list they can read.
    static var spansPerTerm: Int {
        ProcessInfo.processInfo.environment["PARROTFLOW_SPANS_PER_TERM"]
            .flatMap(Int.init) ?? 2
    }

    /// How far the audio may contradict a proposal before it stops being one.
    ///
    /// The rescorer decides on the boosted score, so a term can win a span its
    /// sound lost badly: `Redcrawl` beat "general" by 0.57 boosted and lost by
    /// 5.28 raw, and "in general" is not a rare phrase. A reading the audio
    /// argues against by this much is not a reading, and offering it spends a
    /// menu line on noise.
    ///
    /// Generous on purpose. `versal` -> `Vercel` is 0.82 against and correct,
    /// so the gate has to sit well clear of an ordinary near-tie.
    static var proposalMargin: Float {
        ProcessInfo.processInfo.environment["PARROTFLOW_PROPOSAL_MARGIN"]
            .flatMap(Float.init) ?? 3.0
    }

    static var spotterFloor: Float {
        ProcessInfo.processInfo.environment["PARROTFLOW_SPOTTER_FLOOR"]
            .flatMap(Float.init) ?? -5.5
    }

    /// The term as it should be written where this word stood.
    ///
    /// The rescorer replaces a whole token, so "Mirza's" became "Mirza" and the
    /// possessive was lost — silently, because that substitution auto-applies
    /// and never reaches a menu. The decoder had the grammar right; only the
    /// spelling of the name was in question, and the two are separable.
    ///
    /// Only a trailing possessive is carried. A word that merely ends in the
    /// same letters is not a name plus a suffix, so the match is on the term
    /// followed by an apostrophe.
    static func inflected(_ term: String, like heard: String) -> String {
        let trimmed = heard.trimmingCharacters(in: CharacterSet.alphanumerics.inverted
            .subtracting(CharacterSet(charactersIn: "'\u{2019}s")))
        let lower = trimmed.lowercased()
        for suffix in ["'s", "\u{2019}s"] where lower.hasSuffix(suffix) {
            let stem = String(lower.dropLast(suffix.count))
            if stem == term.lowercased() { return term + suffix }
        }
        return term
    }

    /// Whether a proposal is safe to write without asking anything.
    ///
    /// The rule is the spell-check gate, measured at 38/38 on declines and
    /// 0.00s: never overwrite a real word. Used here as a router rather than a
    /// filter — a real word is not refused, it is passed to the judge, which is
    /// the only thing that can read the sentence.
    ///
    /// Two cases the checker gets wrong on its own, both from
    /// `scripts/validate-judge.py`. A run of capitals is accepted as an acronym,
    /// so `OLAMA` looks like a word and is judged on its lowercase form. And a
    /// term the decoder split into words — "red crawl" for `Redcrawl` — is
    /// two real words that are not the thing that was said, so it is matched
    /// glued instead.
    ///
    /// The score comparison is on the raw numbers. The boosted one already
    /// carries up to 4.5 for being in the vocabulary, and auto-applying on a
    /// margin that the bonus alone created is how `praise` became `Praisy`.
    ///
    /// The split-compound case is the exception, and it is deliberate. "red
    /// crawl" and "Redcrawl" are the same phonemes — the decoder put a space
    /// in them, which is a question about spelling and not about sound. Measured
    /// on a real clip: raw scores −6.26 for the split and −6.67 for the term,
    /// so the audio marginally prefers the split and always will. Requiring the
    /// term to win there would refuse every one of these, which is the only
    /// thing the acoustic pass reliably catches. Where the sound is identical,
    /// being in the vocabulary is the whole of the evidence, and that is what
    /// the bonus is for.
    static func autoApplies(heard: String, term: String, heardScore: Float, termScore: Float) -> Bool {
        let letters = heard.filter { $0.isLetter || $0.isWhitespace }
        if letters.contains(" ") {
            let glued = letters.replacingOccurrences(of: " ", with: "").lowercased()
            return glued == term.lowercased()
        }

        guard termScore > heardScore else { return false }
        let bare = String(letters)
        guard !bare.isEmpty else { return false }
        let forms = bare == bare.uppercased() ? [bare.lowercased()] : [bare, bare.lowercased()]
        return !forms.contains { Replacements.isRealWord($0) }
    }

    /// The transcript, with the names the audio is sure about written in and
    /// the rest published for a judge to decide.
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

            // Diagnostic: what the acoustic search found, before any spelling
            // was consulted. `detections` is computed on every dictation and
            // has never been read.
            if ProcessInfo.processInfo.environment["PARROTFLOW_SPOTTER_DUMP"] != nil {
                for hit in spotted.detections.sorted(by: { $0.score > $1.score }) {
                    Log.write(String(
                        format: "spotter: %@ %.2f at %.2fs-%.2fs",
                        hit.term.text, hit.score, hit.startTime, hit.endTime
                    ))
                }
            }

            let cbw = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count).cbw
            let result = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: config.vocabulary.minSimilarity
            )
            // Not `guard result.wasModified` any more. The acoustic search
            // below runs whether or not the spelling gate proposed anything,
            // and the clips it exists for are exactly the ones where nothing
            // else fired — "deployed on Versailles" has no other term in it.
            let spottedAnything = spotted.detections.contains { $0.score >= Self.spotterFloor }
            guard result.wasModified || spottedAnything else { return .unchanged(text) }

            // Located by the word the decoder wrote, left to right, each
            // occurrence claimed once. The decoded word is in the text by
            // definition — it came out of it — and two proposals sharing a
            // target no longer compete for the same position.
            var claimed: [Range<String.Index>] = []
            var found: [(range: Range<String.Index>, change: VocabularyRescorer.RescoringResult)] = []
            for change in result.replacements where change.shouldReplace {
                guard change.replacementWord != nil else { continue }
                var from = text.startIndex
                while let range = text.range(of: change.originalWord, range: from..<text.endIndex) {
                    if !claimed.contains(where: { $0.overlaps(range) }) {
                        claimed.append(range)
                        found.append((range, change))
                        break
                    }
                    from = range.lowerBound < text.endIndex
                        ? text.index(after: range.lowerBound) : text.endIndex
                }
            }
            found.sort { $0.range.lowerBound < $1.range.lowerBound }

            // A term the decoder split across a word boundary is offered as
            // the wider span too, not only as the word the rescorer settled
            // on. The two compete inside FluidAudio and the shorter one wins
            // on similarity, which is right when it is deciding and wrong when
            // it is proposing: "praise he" is the whole of `Praisy` and
            // "praise" is most of it, so every reading built from the shorter
            // span leaves a word behind. Offered, never applied — a span this
            // far out is exactly the kind only a sentence can settle.
            // The acoustic search, which has no spelling in it.
            //
            // `detections` is what the CTC spotter heard, term by term, with
            // the time it heard it at. It is computed on every dictation for
            // the log-probs above and has never been read. It is the only
            // thing here that can reach a rendering more than three edits from
            // its term: "Versailles" is six from `Vercel` and the BK-tree can
            // never return it, while the spotter puts `Vercel` at -5.28 over
            // exactly those frames.
            //
            // Noisy by nature — every term scores against every span, so a
            // 19-second clip yields ninety hits. Three gates, in order: the
            // best term per stretch of audio, nothing already proposed, and
            // nothing sitting on an ordinary word. FluidAudio's own rescue
            // path skips all three, which is why it altered 370 of 386 clips
            // and is switched off in `rescorerConfig`.
            let spoken = Self.words(from: tokenTimings, in: text)
            let bare = { (s: Substring) in String(s).lowercased().filter(\.isLetter) }
            // Mapped by overlap, and capped per term.
            //
            // Midpoint gating was too strict to be worth its precision: a
            // detection is a third of a second against word timings that are
            // approximate, and the best `Praisy` hit in one clip — the one
            // sitting on the name — covered no word midpoint at all and was
            // dropped, while two worse hits on other spans survived. Largest
            // overlap always yields a word, which is what a menu needs.
            //
            // `spansPerTerm` is the whole budget. A term that fires forty
            // times over a clip contributes at most this many readings, so the
            // menu grows with the vocabulary rather than with the noise.
            if ProcessInfo.processInfo.environment["PARROTFLOW_SPOTTER_DUMP"] != nil {
                for word in spoken {
                    Log.write(String(format: "  word %@ %.2f-%.2f",
                                     String(text[word.range]), word.start, word.end))
                }
            }
            let known = Set(context.terms.map { $0.text.lowercased() })
            var heardSpans: [(range: Range<String.Index>, term: String, score: Float)] = []
            var perTerm: [String: Int] = [:]
            var claimedWords: Set<Int> = []
            for hit in spotted.detections.sorted(by: { $0.score > $1.score })
            where hit.score >= Self.spotterFloor {
                guard perTerm[hit.term.text, default: 0] < Self.spansPerTerm else { continue }

                // The word this detection sits on, plus a neighbour when it
                // covers most of one too — a split name is two words and one
                // detection.
                let overlaps = spoken.indices.map { index -> (Int, Double) in
                    let word = spoken[index]
                    let shared = min(word.end, hit.endTime) - max(word.start, hit.startTime)
                    return (index, max(0, shared) / max(0.01, word.end - word.start))
                }
                guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0.2 else { continue }
                var covered = [best.0]
                for neighbour in [best.0 - 1, best.0 + 1] where spoken.indices.contains(neighbour) {
                    if overlaps[neighbour].1 > 0.5 { covered.append(neighbour) }
                }
                // A detection that lands on a function word has not found a
                // function word. `Praisy` decoded as "praise he" put its best
                // hit on "he", which the ordinary-word guard below then threw
                // away — so reach for the neighbour rather than give up.
                if covered.allSatisfy({ Self.ordinary.contains(bare(text[spoken[$0].range])) }) {
                    let neighbours = [best.0 - 1, best.0 + 1]
                        .filter { spoken.indices.contains($0) && !covered.contains($0) }
                    if let pick = neighbours.max(by: { overlaps[$0].1 < overlaps[$1].1 }) {
                        covered.append(pick)
                    }
                }
                covered.sort()
                guard let first = covered.first, let last = covered.last,
                      !covered.contains(where: claimedWords.contains)
                else { continue }

                // Trailing punctuation is not part of the word. A span of
                // "Versailles." replaced by "Vercel" takes the full stop with
                // it, and the sentence loses its end.
                var upper = spoken[last].range.upperBound
                while upper > spoken[last].range.lowerBound,
                      let before = text.index(upper, offsetBy: -1, limitedBy: text.startIndex),
                      !text[before].isLetter && !text[before].isNumber {
                    upper = before
                }
                let range = spoken[first].range.lowerBound..<upper
                guard !range.isEmpty else { continue }
                let words = text[range].split(whereSeparator: { !$0.isLetter })

                // Already written, already proposed, or every word ordinary.
                //
                // The third guard is about a *different* term: the spotter put
                // `Ollama` at -4.37 over the word "Mirza", which the decoder
                // had already got right. A word that is itself a vocabulary
                // term is not a mistake, whatever else was heard near it.
                guard !words.contains(where: { bare($0) == hit.term.text.lowercased() }),
                      !words.contains(where: { known.contains(bare($0)) }),
                      !found.contains(where: { $0.range.overlaps(range) }),
                      words.contains(where: { !Self.ordinary.contains(bare($0)) })
                else { continue }
                claimedWords.formUnion(covered)
                perTerm[hit.term.text, default: 0] += 1
                heardSpans.append((range, hit.term.text, hit.score))
            }

            // Both sources, not just the rescorer's. The clips this exists for
            // are the ones where only the audio found anything: "praise his
            // work" has no spelling near `Praisy` and arrives entirely from
            // the spotter, so generating variants from `found` alone left it
            // with the one span that strands a word.
            var wider: [(range: Range<String.Index>, heard: String, term: String)] = []
            let anchors: [(range: Range<String.Index>, term: String)] =
                found.map { ($0.range, $0.change.replacementWord ?? "") }
                + heardSpans.map { ($0.range, $0.term) }
            for (range, term) in anchors {
                guard !term.isEmpty else { continue }

                // The word after, and the word after that. A name the decoder
                // split lands as a run rather than a token: `Praisy` came out
                // "praise he", "praise his", "Prissy d". Every one of those
                // leaves a word stranded in any reading built from the shorter
                // span, so the longer span has to be on the menu beside it.
                var ends: [String.Index] = []
                var end = range.upperBound
                for _ in 0..<2 {
                    while end < text.endIndex, text[end] == " " { end = text.index(after: end) }
                    let wordStart = end
                    while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
                    guard end > wordStart else { break }
                    ends.append(end)
                }

                // Every span crossed with every reading of it. The two are
                // independent: "praise his" is 0.45 from `Praisy` and 0.59
                // from `Praisy's`, so testing the possessive only on spans
                // that already passed threw away the one that was right.
                //
                // The possessive is here because the term never carries it and
                // the speaker usually does. "praise his work" is `Praisy's
                // work`, and no span of the transcript spells that — it has to
                // be built rather than found.
                for stop in [range.upperBound] + ends {
                    let phrase = String(text[range.lowerBound..<stop])
                    guard !phrase.isEmpty else { continue }
                    for reading in [term, term + "'s"] {
                        guard phrase.lowercased() != reading.lowercased(),
                              Self.gluedSimilarity(phrase, reading) >= Self.widerSpanFloor,
                              !wider.contains(where: {
                                  $0.range == range.lowerBound..<stop && $0.term == reading
                              })
                        else { continue }
                        wider.append((range.lowerBound..<stop, phrase, reading))
                    }
                }
            }


            // Rebuilt from segments rather than edited in place. A
            // `String.Index` belongs to the string it came from, and reusing
            // one from `text` against a copy being mutated is undefined — it
            // silently dropped every replacement before this was written that
            // way.
            var decided: [(change: VocabularyRescorer.RescoringResult, raw: Float, bonus: Float, applied: Bool, dropped: Bool)] = []
            var rebuilt = ""
            var cursor = text.startIndex
            for (range, change) in found {
                let term = change.replacementWord ?? ""
                let bonus = Self.rescorerConfig.adaptiveCbw(
                    baseCbw: cbw, tokenCount: tokenCounts[term] ?? 0
                )
                let raw = (change.replacementScore ?? 0) - bonus
                let applies = Self.autoApplies(
                    heard: change.originalWord, term: term,
                    heardScore: change.originalScore, termScore: raw
                )
                rebuilt += text[cursor..<range.lowerBound]
                rebuilt += applies
                    ? Self.inflected(term, like: change.originalWord) : String(text[range])
                cursor = range.upperBound
                // Dropped when the audio argues hard against it — neither
                // applied nor offered. Kept in the list so the index still
                // lines up with `found`.
                let dropped = !applies && change.originalScore - raw > Self.proposalMargin
                decided.append((change, raw, bonus, applies, dropped))
            }
            rebuilt += text[cursor...]
            let written = rebuilt

            // Where a span in `text` ends up in `written`, and which occurrence
            // of its own words that makes it.
            //
            // `nth` used to be a per-spelling counter, incremented in the order
            // proposals happened to be built. That is only right when a
            // spelling appears once. On a sentence naming Versailles twice —
            // the castle and the deployment — the counter labelled the second
            // one 0, so the judge was offered a menu that rewrote the castle
            // and left the deployment alone. Counted from the position now.
            let shifts: [(at: Int, delta: Int)] = zip(found, decided).compactMap { pair in
                guard pair.1.applied, !pair.1.dropped else { return nil }
                let at = text.distance(from: text.startIndex, to: pair.0.range.lowerBound)
                let was = text.distance(from: pair.0.range.lowerBound, to: pair.0.range.upperBound)
                return (at, (pair.1.change.replacementWord ?? "").count - was)
            }
            func occurrence(of phrase: String, at start: String.Index) -> Int {
                let raw = text.distance(from: text.startIndex, to: start)
                let moved = raw + shifts.filter { $0.at < raw }.reduce(0) { $0 + $1.delta }
                guard let limit = written.index(
                    written.startIndex, offsetBy: moved, limitedBy: written.endIndex
                ) else { return 0 }
                var count = 0
                var from = written.startIndex
                while let hit = written.range(of: phrase, range: from..<written.endIndex),
                      hit.lowerBound < limit {
                    count += 1
                    from = hit.upperBound
                }
                return count
            }

            // Every proposal, named, with what was done about it. This is the
            // stage most likely to be blamed for a sentence nobody recognises,
            // and the log is where that gets settled.
            var made: [String] = []
            var proposals: [Proposal] = []
            for ((range, _), (change, raw, bonus, applied, dropped)) in zip(found, decided) {
                if dropped {
                    Log.write(String(
                        format: "vocabulary: \"%@\" -> \"%@\" dropped, audio prefers what was written by %.2f",
                        change.originalWord, change.replacementWord ?? "",
                        change.originalScore - raw))
                    continue
                }
                let term = change.replacementWord ?? ""
                Log.write(String(
                    format: "vocabulary: \"%@\" -> \"%@\" %@ (raw %.2f vs %.2f, bonus %.2f) (%@)",
                    change.originalWord, term, applied ? "applied" : "proposed",
                    raw, change.originalScore, bonus, change.reason
                ))
                made.append(String(
                    format: "%@ -> %@ @ %.2f/%.2f",
                    change.originalWord, term, change.originalScore, raw
                ))
                let nth = applied
                    ? 0 : occurrence(of: change.originalWord, at: range.lowerBound)
                proposals.append(Proposal(
                    heard: change.originalWord,
                    term: Self.inflected(term, like: change.originalWord), nth: nth,
                    heardScore: change.originalScore, termScore: raw,
                    bonus: bonus, applied: applied
                ))
            }

            // The wider spans last, and only where the narrow one was left in
            // the text. Applied means the word is gone and there is nothing
            // for a longer reading to sit on. No scores: nothing scored these
            // acoustically, and inventing a number for the judge to weigh
            // would be worse than telling it there is none.
            let untouched = Set(zip(found, decided).compactMap { ($0.1.applied || $0.1.dropped) ? nil : $0.0.range })
                .union(heardSpans.map(\.range))
            for span in wider where untouched.contains(where: { $0.overlaps(span.range) }) {
                let nth = occurrence(of: span.heard, at: span.range.lowerBound)
                Log.write(
                    "vocabulary: \"\(span.heard)\" -> \"\(span.term)\" also offered"
                        + String(format: " (span %.2f)", Self.gluedSimilarity(span.heard, span.term))
                )
                proposals.append(Proposal(
                    heard: span.heard, term: span.term, nth: nth,
                    heardScore: 0, termScore: 0, bonus: 0, applied: false
                ))
            }

            // The acoustic hits last, and only where nothing was written over
            // them. Never applied: the spotter says a term is in the audio, not
            // that the word standing there is wrong, and only the sentence can
            // tell those apart.
            for span in heardSpans {
                let phrase = String(text[span.range])
                guard written.contains(phrase) else { continue }
                let nth = occurrence(of: phrase, at: span.range.lowerBound)
                Log.write(String(
                    format: "vocabulary: \"%@\" -> \"%@\" heard in the audio (spotter %.2f)",
                    phrase, span.term, span.score
                ))
                proposals.append(Proposal(
                    heard: phrase, term: span.term, nth: nth,
                    heardScore: 0, termScore: span.score, bonus: 0, applied: false
                ))
            }
            return Outcome(
                text: Self.restorePunctuation(from: text, to: written),
                // Every proposal, not just the ones the rescorer made. A clip
                // whose only finding came from the audio still has to wake the
                // judge, and `when: vocabulary.count > 0` is how it does that.
                count: proposals.count,
                changes: made.joined(separator: "; "),
                proposals: proposals
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
