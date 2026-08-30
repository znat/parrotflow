import FluidAudio
import Foundation

/// Finds the names in `vocabulary:` in a transcript that got them wrong, by
/// matching sound rather than spelling — and, for all but the certain ones,
/// offers them rather than writing them.
///
/// This runs inside transcription, not in the pipeline. It needs the audio and
/// the token timings the decoder produced, and a pipeline stage only ever sees
/// text — once `numbers` has turned "nineteen" into "19" the timings no longer
/// line up with the words.
///
/// ## Propose, do not decide
///
/// The pass used to substitute and report what it had done. That destroys the
/// evidence: once "praise" is `Praisy`, no later stage can know what was heard
/// (finding F2). So the pass writes only what it is sure about — see
/// `autoApplies` — and everything else comes back as a `Proposal` carrying the
/// decoded word, the term, **where it sits in the returned text**, and the two
/// acoustic scores. The `vocabulary:` pipeline stage builds a menu from those
/// and lets a model pick a whole sentence.
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
/// Those numbers describe a pass that substituted. This one proposes, so the
/// similarity it is given is `offer_below:` and a wrong fire costs a menu line
/// rather than a rewritten word — see `Config.Vocabulary.offerBelow`.
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
    /// printed says the audio preferred the term when often it did not (F4).
    private var tokenCounts: [String: Int] = [:]

    /// How many real terms are loaded. Not `context.terms.count`, which also
    /// counts one entry per pronunciation.
    ///
    /// F9 called this a live bug: pronunciation entries inflate `forVocabSize:`
    /// and shift the bonus for every term. Measured on FluidAudio 0.15.5, it is
    /// not — `ContextBiasingConstants.rescorerConfig(forVocabSize:)` returns
    /// `cbw: 4.5` at every size, and the only field that moves with size is a
    /// `minSimilarity` this file never reads, because `apply` passes
    /// `offer_below` instead. Adding ten renderings to one term leaves every
    /// other term's logged bonus identical, before and after this change.
    ///
    /// Fixed anyway, and it is not bookkeeping. The number this asks for is the
    /// size of the vocabulary; the size of the context is a different number
    /// that happens to have been equal until this PR. One upstream release that
    /// makes `cbw` depend on size again turns that coincidence into a bonus
    /// that moves whenever somebody corrects a name.
    private var termCount = 0

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
        // The pronunciations are part of what gets built, so a list that
        // changed has to rebuild the context exactly as a floor does.
        let heard = config.vocabularyPronunciations
        let signature = terms.map { "\($0.text):\($0.offerBelow)" }
            + heard.map { "\($0.term)~\($0.heard)" }
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
                text: term.text, ctcTokenIds: ids, minSimilarity: term.offerBelow
            )
        }
        self.tokenCounts = counts
        self.termCount = built.count
        guard !built.isEmpty else {
            loadedFor = signature
            return
        }

        // Every rendering registered as a *pronunciation* of its term rather
        // than as a spelling to substitute.
        //
        // `CustomVocabularyTerm` takes its CTC token ids explicitly, and
        // nothing requires them to be the tokenisation of `text`. So `Vercel`
        // goes in a second time carrying the tokens of "Versailles", and the
        // spotter searches the audio for that sound and reports the term.
        //
        // `minSimilarity` is set past 1 so the rescorer never picks one of
        // these as a spelling candidate — it compares spellings, and these
        // carry the canonical spelling, so they would only duplicate the entry
        // above. **The spotter does not consult it, which is the whole trick.**
        // It is how `Versailles` reaches `Vercel` at all: the two are 0.40
        // similar, so no floor can find them, and the spotter puts the term
        // over those frames at −2.28 rather than the −5.28 the term's own
        // spelling gets.
        //
        // The table already holds these. As rules alone they rewrite every
        // "Versailles" including the palace; as pronunciations they also fire
        // where the audio agrees, and on one clip the two Versailles separate
        // by about a nat.
        var pronunciations: [CustomVocabularyTerm] = []
        var mute: [String] = []
        for (name, rendering) in heard {
            let ids = tokenizer.encode(rendering)
            guard !ids.isEmpty else {
                mute.append("\(name)/\(rendering) tokenises to nothing")
                continue
            }
            pronunciations.append(CustomVocabularyTerm(
                text: name, ctcTokenIds: ids, minSimilarity: 1.01
            ))
        }
        // The prototype skipped every term shorter than five characters here,
        // silently. The real rule is `Config.vocabularyPronunciations`: a
        // pronunciation reports its *term*, so it can only be registered for a
        // term the pass already knows how to price. Whatever that drops is
        // named rather than dropped in silence.
        let unsearched = config.vocabularyRules.count - heard.count
        if unsearched > 0 {
            mute.append("\(unsearched) on terms not searched for by sound")
        }
        if !pronunciations.isEmpty || !mute.isEmpty {
            Log.write("vocabulary: \(pronunciations.count) pronunciation(s) searched"
                + " for by sound"
                + (mute.isEmpty ? "" : "; rules only: \(mute.joined(separator: ", "))"))
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
    /// `range` is a range **in `Outcome.text`** — the string this pass hands
    /// back. Not an occurrence count, not a character offset in a JSON blob.
    /// A running counter was the previous design and it was wrong twice over:
    /// it labelled the second `Versailles` in one sentence as the first, so
    /// the menu rewrote the castle and left the deployment alone (F3), and
    /// nothing survives a stage that edits the text anyway (F10). The stage
    /// that reads these runs where the ranges are still valid, and says so
    /// when they are not.
    ///
    /// The scores are optional and absent means absent (F6). A spotter-only
    /// hit has no score for the word the decoder wrote — nothing measured it —
    /// and writing 0 there made the judge read "heard perfectly" off a number
    /// nobody had computed. Zero is a legal best score in nats, so it cannot
    /// also be the sentinel.
    struct Proposal: Sendable {
        let heard: String
        let term: String
        /// `term`, before inflection and trailing punctuation were added for
        /// display. The vocabulary's own key — `config.vocabulary.terms`
        /// looks things up by this, not by `term`.
        let canonicalTerm: String
        let range: Range<String.Index>
        /// The decoded word's CTC score. Raw. Absent for a spotter-only hit.
        let heardScore: Float?
        /// The term's CTC score with the vocabulary bonus removed, so the two
        /// numbers mean the same thing. Absent for a span variant, which
        /// nothing scored acoustically.
        let termScore: Float?
        /// The bonus that was taken off. Kept so the log can show its work.
        let bonus: Float?
        /// False when only a judge should decide — see `autoApplies`.
        let applied: Bool
    }

    /// What one pass did, for the pipeline to read.
    ///
    /// `changes` stays `heard -> written @ a/b`, joined by `; `, because that
    /// is what `replacements` publishes and what every existing stage reads.
    /// `proposals` is the same information with positions, for the stage that
    /// has to put a word back rather than judge that it was written.
    ///
    /// `text` travels with them. The ranges index this string and no other,
    /// and a `String.Index` used against a different string is undefined
    /// behaviour rather than a wrong answer (F13).
    struct Outcome: Sendable {
        let text: String
        let count: Int
        let changes: String
        let proposals: [Proposal]

        static func unchanged(_ text: String) -> Outcome {
            Outcome(text: text, count: 0, changes: "", proposals: [])
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

    // MARK: - Finding things in a string

    /// Every occurrence of `phrase` in `text`, on word boundaries.
    ///
    /// Never a bare `range(of:)`. That matches inside a longer word — "update"
    /// lands in "updates", "Mira" lands in "Mirage" — and a span that is off by
    /// a word puts the menu's alternative on the wrong noun (F9). A boundary is
    /// only required on a side where the phrase itself ends in a letter or a
    /// digit, so "Olama?" still matches the word it is.
    static func spans(
        of phrase: String, in text: String, from cursor: String.Index? = nil,
        ignoringCase: Bool = false
    ) -> [Range<String.Index>] {
        guard !phrase.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var from = cursor ?? text.startIndex
        while from <= text.endIndex,
              let hit = text.range(
                  of: phrase, options: ignoringCase ? [.caseInsensitive] : [],
                  range: from..<text.endIndex
              ) {
            if bounded(hit, in: text) { found.append(hit) }
            guard hit.lowerBound < text.endIndex else { break }
            from = text.index(after: hit.lowerBound)
        }
        return found
    }

    private static func bounded(_ hit: Range<String.Index>, in text: String) -> Bool {
        let word = { (character: Character) in character.isLetter || character.isNumber }
        if let first = text[hit].first, word(first), hit.lowerBound > text.startIndex,
           word(text[text.index(before: hit.lowerBound)]) {
            return false
        }
        if let last = text[hit].last, word(last), hit.upperBound < text.endIndex,
           word(text[hit.upperBound]) {
            return false
        }
        return true
    }

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
        // On boundaries, like everything else here: the cursor alone let a
        // short word land inside a longer one and take every following word's
        // position with it.
        var out: [(Range<String.Index>, Double, Double)] = []
        var cursor = text.startIndex
        for word in built where !word.text.isEmpty {
            guard let range = spans(of: word.text, in: text, from: cursor).first else {
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

    /// How many **spotter** spans one term may contribute. Not the menu.
    ///
    /// It read "how many readings one term may contribute to a menu", which is
    /// not what it does and not where it is used. It gates `acousticSpans`
    /// only, so it never saw the rescorer's own proposals, the wider spans, or
    /// a `replacements` rule — and a term reaches a menu from all four. The
    /// menu-level cap is `VocabularyJudge.Caps.perTerm`, which is applied where
    /// the four meet.
    ///
    /// Kept where it is because it is cheaper here: a detection refused now
    /// never becomes a proposal, and a 19-second clip yields ninety of them.
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
    /// `decide_above:` in `vocabulary.yaml` is the setting. The env override
    /// stays because the harness sweeps this number, and a harness that has to
    /// rewrite the user's file to measure one point is a harness that
    /// eventually leaves it rewritten.
    static func proposalMargin(_ config: Config) -> Float {
        ProcessInfo.processInfo.environment["PARROTFLOW_PROPOSAL_MARGIN"]
            .flatMap(Float.init) ?? config.vocabulary.decideAbove
    }

    /// How well the spotter has to hear a term before its span is offered.
    ///
    /// Raised from -5.5 to -5.0 when pronunciations arrived, and the reason is
    /// arithmetic rather than taste. A term's spotter score over a span is the
    /// best of its search targets, so registering fourteen renderings of
    /// `Praisy` makes it fifteen draws instead of one — every span in every
    /// clip scores a little higher for that term, including the spans where it
    /// was never said. The old floor was measured against terms alone and lets
    /// the extra draws through: on `16-16-25` it admitted `Praisy` over "heard
    /// by" and "judge", `Ollama` over "idea was to" and `Claude` over
    /// "decoder", six slots in total, and the judge stage declines past four.
    /// A clip that was right became a clip with no menu at all.
    ///
    /// Measured on `menu-recall.py` with the renderings registered:
    ///
    ///     floor   recall   picked
    ///     -5.5     30/37    27/37    the extra draws cross max_slots
    ///     -5.2     31/37    26/37
    ///     -5.0     31/37    27/37    parity, and the plateau starts
    ///     -4.8     31/37    27/37
    ///
    /// -5.0 rather than -4.8 because it is the loose end of the plateau: the
    /// two score the same here, and the looser one asks less of a speaker whose
    /// renderings this set does not contain.
    ///
    /// -5.0 is not a tightening of what the audio may find. The hit this whole
    /// PR exists for — `Vercel` over "Versailles" — moves from -5.28 to -2.28
    /// once the rendering is registered, so it clears either number by a
    /// distance. What -5.0 cuts is the tail that got there by having more
    /// draws.
    static var spotterFloor: Float {
        ProcessInfo.processInfo.environment["PARROTFLOW_SPOTTER_FLOOR"]
            .flatMap(Float.init) ?? -5.0
    }

    /// The term as it should be written where this word stood.
    ///
    /// The rescorer replaces a whole token, so "Mirza's" became "Mirza" and the
    /// possessive was lost — silently, because that substitution auto-applies
    /// and never reaches a menu. The decoder had the grammar right; only the
    /// spelling of the name was in question, and the two are separable.
    ///
    /// Only a trailing possessive is carried, and only where dropping it brings
    /// the word closer to the term. This used to ask whether the stem was
    /// spelled exactly like the term, which is the one case where nothing
    /// needed carrying: a substitution runs *because* the decoder spelled the
    /// name differently. `mathieu` is not `matthieu`, so the test failed and
    /// the bare term came back. It carried the possessive only where the
    /// possessive was never at risk.
    ///
    /// The reason that test was narrow still holds — a word that merely ends in
    /// the same letters is not a name plus a suffix — so something still has to
    /// refuse. `let's`, `it's` and `he's` all end in `'s` and none is a
    /// possessive; writing `Praisy's` over one is worse than writing `Praisy`.
    ///
    /// A word list is not what separates them. Take the `'s` off a possessive
    /// and what is left is the name the decoder was trying to spell, so the
    /// match improves. Take it off a contraction and what is left is a short
    /// function word that was never the name, so the match gets worse — the
    /// length penalty in `gluedSimilarity` does that. So the test is a
    /// comparison, not a threshold: it needs no floor and no list, and it
    /// cannot fire on a token the rescorer did not already match.
    ///
    /// Measured on the 5672 archive tokens ending in `'s` (2026-08-10). 4660
    /// are contractions, in 14 spellings, and every one is refused — the
    /// closest is "Here" at 0.41 against `Vercel`. All 32 substitutions the
    /// pass really made over such a token are name possessives. The old test
    /// carried 11 of them, all `Mirza's` over `Mirza`; this carries 31.
    ///
    /// One shape can still fool it: a term shorter than a contraction's stem,
    /// where dropping a character helps the length ratio instead of hurting it.
    /// That needs a two-letter term, and there is none.
    ///
    /// The auto-apply path reaches this far less often since `dropsPossessive`
    /// sends that pair to the judge. It is still what writes the reading the
    /// judge is offered, which is where the possessive now has to survive.
    static func inflected(_ term: String, like heard: String) -> String {
        guard let (stem, suffix) = possessive(in: heard), !stem.isEmpty,
              gluedSimilarity(stem, term) >= gluedSimilarity(stem + suffix, term)
        else { return term }
        return term + suffix
    }

    /// The trailing `'s` a word carries, and the stem under it — lowercased,
    /// with surrounding punctuation dropped and the apostrophe kept.
    ///
    /// Both apostrophes. The recogniser writes the typographic one and a
    /// keyboard writes the straight one, and a decoded token can be either.
    ///
    /// This says nothing about whether the `'s` is a possessive. `it's` and
    /// `let's` come back from here too; what separates them is the comparison
    /// in `inflected` and, for the gate, the term.
    static func possessive(in word: String) -> (stem: String, suffix: String)? {
        let trimmed = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted
            .subtracting(CharacterSet(charactersIn: "'\u{2019}s")))
        let lower = trimmed.lowercased()
        guard let suffix = ["'s", "\u{2019}s"].first(where: { lower.hasSuffix($0) })
        else { return nil }
        return (String(lower.dropLast(suffix.count)), suffix)
    }

    /// The punctuation a replaced word carried, so the sentence keeps its end.
    ///
    /// The rescorer replaces the word and not what followed it, so "on Olama?"
    /// came back as "on Ollama" and the question mark was gone. Measured on the
    /// archive: it happened to 4 of the 8 substitutions at the shipped setting.
    ///
    /// Carried while the text is being rebuilt rather than restored by a pass
    /// over the finished string. A second pass would move characters after
    /// every position this file has just worked out, and the proposals are
    /// positions.
    static func trailingMarks(of phrase: String) -> String {
        let marks: Set<Character> = [".", ",", "?", "!", ":", ";"]
        return String(phrase.reversed().prefix { marks.contains($0) }.reversed())
    }

    /// Whether a proposal is safe to write without asking anything.
    ///
    /// One rule is about the sentence and comes first, because no word list
    /// can see it: a possessive the heard text carries and the term does not
    /// — see `dropsPossessive`.
    ///
    /// The rest is the spell-check gate, measured at 38/38 on declines
    /// and 0.00s: never overwrite a real word. Used here as a router rather
    /// than a filter — a real word is not refused, it is passed to the judge,
    /// which is the only thing that can read the sentence.
    ///
    /// Two word lists have to agree, not one. `Replacements.isRealWord` is a
    /// dictionary and has no first names in it, so `Frederick` looked like a
    /// word nobody uses and "Um not Peter, uh Frederick." was rewritten to
    /// `Redrock` with nothing reading the sentence. `WordPieces` covers that
    /// blind spot and has the opposite one, and it answers `nil` when its list
    /// is missing — so a broken resource sends the proposal to the judge
    /// rather than writing it in.
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
    static func autoApplies(
        heard: String, term: String, heardScore: Float, termScore: Float
    ) -> Bool {
        let letters = heard.filter { $0.isLetter || $0.isWhitespace }
        if letters.contains(" ") {
            let glued = letters.replacingOccurrences(of: " ", with: "").lowercased()
            return glued == term.lowercased()
        }

        guard termScore > heardScore else { return false }
        let bare = String(letters)
        guard !bare.isEmpty else { return false }
        guard !dropsPossessive(heard: heard, term: term) else { return false }
        return unseenWord(bare)
    }

    /// Whether writing the term here would take away a possessive the speaker
    /// said.
    ///
    /// Asked before the word test, because the word test cannot see it. `bare`
    /// is letters only, so `Mirza's` is looked up as `Mirzas` — a form neither
    /// list has ever seen, where `Mirza` itself is known to one of them. The
    /// apostrophe walks the proposal straight past both lists: measured on the
    /// shipped binary, `--word-gate Frederick` says `judge` and
    /// `--word-gate "Frederick's"` said `auto-apply`.
    ///
    /// A rule and not a threshold. "Mirza's thoughts" is not "Mirza thoughts";
    /// dropping a possessive changes what the sentence says, in every sentence,
    /// so there is nothing here to tune and nothing to drift. What it does is
    /// route: the proposal is not refused, it goes to the judge, which is the
    /// only thing that reads the sentence.
    ///
    /// One direction only. `Matthew at` -> `Matthieu's` is the same class the
    /// other way round — the term carries the possessive and the decoded span
    /// does not — and that correction is right. Nothing here fires on it.
    ///
    /// A contraction reaches the judge too, since `it's` also ends in `'s`.
    /// That is the safe direction and it is nearly free: a contraction is a
    /// real word, so `unseenWord` was already sending it there.
    static func dropsPossessive(heard: String, term: String) -> Bool {
        possessive(in: heard) != nil && possessive(in: term) == nil
    }

    /// The word half of the gate: both lists have to say they have never seen
    /// it, and a list that cannot answer counts as a no.
    ///
    /// Split out so `--word-gate` scores the shipped test instead of a copy of
    /// it — the compromise `scripts/real-words.swift` had to make and this does
    /// not. The rest of `autoApplies` is about one proposal, with scores and a
    /// position in a sentence; this is about one word.
    ///
    /// The uppercase form is asked lowercased only. The spell checker waves
    /// through any run of capitals, so `OLAMA` came back as a known word — see
    /// `Replacements.isRealWord`.
    static func unseenWord(_ bare: String) -> Bool {
        let forms = bare == bare.uppercased() ? [bare.lowercased()] : [bare, bare.lowercased()]
        guard !forms.contains(where: { Replacements.isRealWord($0) }) else { return false }
        return WordPieces.knows(bare) == false
    }

    /// The masked language model, once per process, and only if it is already
    /// on disk. `SentenceModel` fetches it in the background after the first
    /// English dictation; nothing here waits for that.
    private var loadedSlotGate: SlotGate?
    private var slotGateFailed = false

    private func slotGate() async -> SlotGate? {
        if let loadedSlotGate { return loadedSlotGate }
        guard !slotGateFailed, SentenceModel.isCached else { return nil }
        do {
            loadedSlotGate = SlotGate(probe: try await SentenceProbe.load())
        } catch {
            slotGateFailed = true
            Log.write("vocabulary: no slot gate (\(error.localizedDescription)); the judge decides")
        }
        return loadedSlotGate
    }

    /// Where the model tier sends a proposal the lexical gate did not settle.
    ///
    /// `judge` on everything it cannot answer — no cached model, a probe that
    /// threw, a possessive the term would drop. Never apply and never decline
    /// without the model, which is the shape `WordPieces.knows` already has and
    /// is there for this reason.
    ///
    /// The possessive is asked here and not inside `SlotGate`. It is a rule
    /// about the pair, it already routes to the judge in `autoApplies`, and the
    /// slot would otherwise be free to overrule it.
    private func slotRoute(
        heard: String, term: String, in text: String, at range: Range<String.Index>
    ) async -> SlotGate.Route {
        guard !Self.dropsPossessive(heard: heard, term: term),
              let gate = await slotGate() else { return .judge }
        do {
            let reading = try gate.read(in: text, at: range)
            Log.write(
                "vocabulary: \"\(heard)\" -> \"\(term)\" slot wants"
                    + " \(reading.tag.isEmpty ? "nothing nameable" : reading.tag)"
                    + (reading.rank.map { ", rank \($0) of \(reading.windows)" } ?? "")
                    + " — \(reading.route.rawValue)"
            )
            return reading.route
        } catch {
            Log.write(
                "vocabulary: the slot gate could not read \"\(heard)\""
                    + " (\(error.localizedDescription)); the judge decides"
            )
            return .judge
        }
    }

    /// The transcript, with the names the audio is sure about written in and
    /// the rest published for a judge to decide.
    ///
    /// Returns the text unchanged on every failure. A name that stays misheard
    /// is a worse transcript; a dictation that does not arrive is no transcript.
    func apply(
        to text: String, samples: [Float], tokenTimings: [TokenTiming], config: Config
    ) async -> Outcome {
        // Above every guard below, on purpose (F11). The word dump is what
        // `scripts/mine-pronunciations.py` reads to learn how a name comes out,
        // and it used to print from inside the acoustic search — which only
        // runs once something has already fired. So mining could only ever
        // widen a term the pass already found, and the clips that matter most
        // are the ones where nothing fired at all. Nothing here needs the
        // spotter: the words and their times come out of the decoder.
        if ProcessInfo.processInfo.environment["PARROTFLOW_SPOTTER_DUMP"] != nil {
            for word in Self.words(from: tokenTimings, in: text) {
                Log.write(String(format: "  word %@ %.2f-%.2f",
                                 String(text[word.range]), word.start, word.end))
            }
        }
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
            // was never read until the acoustic search below started reading it.
            if ProcessInfo.processInfo.environment["PARROTFLOW_SPOTTER_DUMP"] != nil {
                for hit in spotted.detections.sorted(by: { $0.score > $1.score }) {
                    Log.write(String(
                        format: "spotter: %@ %.2f at %.2fs-%.2fs",
                        hit.term.text, hit.score, hit.startTime, hit.endTime
                    ))
                }
            }

            // The number of *terms*, not the size of the context — see
            // `termCount` for what F9 claimed here and what measures (F9).
            let cbw = ContextBiasingConstants.rescorerConfig(
                forVocabSize: termCount
            ).cbw
            let result = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: config.vocabulary.offerBelow
            )
            // Not `guard result.wasModified` any more. The acoustic search
            // below runs whether or not the spelling gate proposed anything,
            // and the clips it exists for are exactly the ones where nothing
            // else fired — "deployed on Versailles" has no other term in it.
            let spottedAnything = spotted.detections.contains { $0.score >= Self.spotterFloor }
            guard result.wasModified || spottedAnything else { return .unchanged(text) }

            let found = Self.locate(result.replacements, in: text)
            let heardSpans = Self.acousticSpans(
                spotted.detections, in: text, timings: tokenTimings,
                known: Set(context.terms.map { $0.text.lowercased() }), avoiding: found.map(\.range)
            )
            let wider = Self.widerSpans(
                in: text,
                anchors: found.map { ($0.range, $0.change.replacementWord ?? "") }
                    + heardSpans.map { ($0.range, $0.term) }
            )

            // Rebuilt from segments rather than edited in place. A
            // `String.Index` belongs to the string it came from, and reusing
            // one from `text` against a copy being mutated is undefined — it
            // silently dropped every replacement before this was written that
            // way.
            var decided: [
                (raw: Float, bonus: Float, applied: Bool, dropped: Bool, declined: Bool)
            ] = []
            let margin = Self.proposalMargin(config)
            let english = Pipeline.language(of: text, config: config) == "en"
            var rebuilt = ""
            var cursor = text.startIndex
            // Where a position in `text` lands in `rebuilt`, as a running
            // character delta. Applied spans are the only thing that moves
            // anything, so one entry each is the whole record.
            var shifts: [(at: Int, delta: Int)] = []
            for (range, change) in found {
                let term = change.replacementWord ?? ""
                let bonus = Self.rescorerConfig.adaptiveCbw(
                    baseCbw: cbw, tokenCount: tokenCounts[term] ?? 0
                )
                let raw = (change.replacementScore ?? 0) - bonus
                let lexical = Self.autoApplies(
                    heard: change.originalWord, term: term,
                    heardScore: change.originalScore, termScore: raw
                )
                // Dropped when the audio argues hard against it — neither
                // applied nor offered.
                let dropped = !lexical && change.originalScore - raw > margin
                // The model tier, on what the free tier did not settle.
                let route = lexical || dropped || !english
                    ? SlotGate.Route.judge
                    : await slotRoute(heard: change.originalWord, term: term, in: text, at: range)
                let applies = lexical || route == .apply
                rebuilt += text[cursor..<range.lowerBound]
                let was = String(text[range])
                let now = applies
                    ? Self.inflected(term, like: change.originalWord) + Self.trailingMarks(of: was)
                    : was
                rebuilt += now
                if applies {
                    shifts.append((
                        at: text.distance(from: text.startIndex, to: range.lowerBound),
                        delta: now.count - was.count
                    ))
                }
                cursor = range.upperBound
                // Kept in the list so the index still lines up with `found`.
                decided.append((raw, bonus, applies, dropped, route == .decline))
            }
            rebuilt += text[cursor...]
            let written = rebuilt

            /// The same span, in the string this pass hands back. Nil when an
            /// applied replacement moved or rewrote part of it — a reading of
            /// words that are no longer there is not a reading.
            func moved(_ range: Range<String.Index>, holding phrase: String) -> Range<String.Index>? {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let shifted = start + shifts.filter { $0.at < start }.reduce(0) { $0 + $1.delta }
                guard shifted >= 0,
                      let from = written.index(
                          written.startIndex, offsetBy: shifted, limitedBy: written.endIndex
                      ),
                      let to = written.index(
                          from, offsetBy: phrase.count, limitedBy: written.endIndex
                      ),
                      written[from..<to] == phrase
                else { return nil }
                return from..<to
            }

            // Every proposal, named, with what was done about it. This is the
            // stage most likely to be blamed for a sentence nobody recognises,
            // and the log is where that gets settled.
            var made: [String] = []
            var proposals: [Proposal] = []
            for ((range, change), verdict) in zip(found, decided) {
                if verdict.dropped {
                    Log.write(String(
                        format: "vocabulary: \"%@\" -> \"%@\" dropped, audio prefers what was written by %.2f",
                        change.originalWord, change.replacementWord ?? "",
                        change.originalScore - verdict.raw))
                    continue
                }
                if verdict.declined {
                    Log.write(
                        "vocabulary: \"\(change.originalWord)\" -> "
                            + "\"\(change.replacementWord ?? "")\" declined,"
                            + " no name fits that slot"
                    )
                    continue
                }
                let term = change.replacementWord ?? ""
                Log.write(String(
                    format: "vocabulary: \"%@\" -> \"%@\" %@ (raw %.2f vs %.2f, bonus %.2f) (%@)",
                    change.originalWord, term, verdict.applied ? "applied" : "proposed",
                    verdict.raw, change.originalScore, verdict.bonus, change.reason
                ))
                made.append(String(
                    format: "%@ -> %@ @ %.2f/%.2f",
                    change.originalWord, term, change.originalScore, verdict.raw
                ))
                // The reading carries the span's punctuation, applied or not.
                // The rescorer's word is the whole token, so "retry." replaced
                // by "Arexvy" costs the sentence its full stop — and on a menu
                // that reads as a reading nobody could have said: "we want to
                // have a Arexvy And then". A judge should never be offered one.
                let reading = Self.inflected(term, like: change.originalWord)
                    + Self.trailingMarks(of: String(text[range]))
                let holds = verdict.applied ? reading : String(text[range])
                guard let placed = moved(range, holding: holds) else { continue }
                proposals.append(Proposal(
                    heard: change.originalWord, term: reading, canonicalTerm: term, range: placed,
                    heardScore: change.originalScore, termScore: verdict.raw,
                    bonus: verdict.bonus, applied: verdict.applied
                ))
            }

            // The wider spans last, and only where the narrow one was left in
            // the text. Applied means the word is gone and there is nothing
            // for a longer reading to sit on. No scores: nothing scored these
            // acoustically, and inventing a number for the judge to weigh
            // would be worse than telling it there is none (F6).
            //
            // A declined span still counts as untouched. The slot gate refused
            // a name over those words; a wider span is a different reading over
            // different words, and refusing it too would lose a name on a
            // question nothing asked.
            let untouched = Set(
                zip(found, decided).compactMap { ($0.1.applied || $0.1.dropped) ? nil : $0.0.range }
            ).union(heardSpans.map { $0.range })
            for span in wider where untouched.contains(where: { $0.overlaps(span.range) }) {
                guard let placed = moved(span.range, holding: span.heard) else { continue }
                Log.write(
                    "vocabulary: \"\(span.heard)\" -> \"\(span.term)\" also offered"
                        + String(format: " (span %.2f)", Self.gluedSimilarity(span.heard, span.term))
                )
                proposals.append(Proposal(
                    heard: span.heard,
                    term: span.term + Self.trailingMarks(of: span.heard), canonicalTerm: span.canonical,
                    range: placed,
                    heardScore: nil, termScore: nil, bonus: nil, applied: false
                ))
            }

            // The acoustic hits last, and only where nothing was written over
            // them. Never applied: the spotter says a term is in the audio, not
            // that the word standing there is wrong, and only the sentence can
            // tell those apart. No `heardScore` — the spotter scored the term,
            // not the word the decoder wrote, and there is no second number.
            for span in heardSpans {
                let phrase = String(text[span.range])
                guard let placed = moved(span.range, holding: phrase) else { continue }
                Log.write(String(
                    format: "vocabulary: \"%@\" -> \"%@\" heard in the audio (spotter %.2f)",
                    phrase, span.term, span.score
                ))
                proposals.append(Proposal(
                    heard: phrase, term: span.term, canonicalTerm: span.term, range: placed,
                    heardScore: nil, termScore: span.score, bonus: nil, applied: false
                ))
            }
            return Outcome(
                text: written,
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

    // MARK: - Where the rescorer's replacements sit

    /// The rescorer's proposals, located by the word the decoder wrote.
    ///
    /// Left to right, each occurrence claimed once. The decoded word is in the
    /// text by definition — it came out of it — and two proposals sharing a
    /// target no longer compete for the same position.
    private static func locate(
        _ replacements: [VocabularyRescorer.RescoringResult], in text: String
    ) -> [(range: Range<String.Index>, change: VocabularyRescorer.RescoringResult)] {
        var claimed: [Range<String.Index>] = []
        var found: [(Range<String.Index>, VocabularyRescorer.RescoringResult)] = []
        for change in replacements where change.shouldReplace {
            guard change.replacementWord != nil else { continue }
            guard let range = spans(of: change.originalWord, in: text)
                .first(where: { hit in !claimed.contains { $0.overlaps(hit) } })
            else { continue }
            claimed.append(range)
            found.append((range, change))
        }
        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    // MARK: - The acoustic search, which has no spelling in it

    /// Spans the CTC spotter heard a term over, as word ranges in the text.
    ///
    /// `detections` is what the spotter heard, term by term, with the time it
    /// heard it at. It is the only thing here that can reach a rendering more
    /// than three edits from its term: "Versailles" is six from `Vercel` and
    /// the BK-tree can never return it, while the spotter puts `Vercel` at
    /// -5.28 over exactly those frames.
    ///
    /// Noisy by nature — every term scores against every span, so a 19-second
    /// clip yields ninety hits. Three gates, in order: the best term per
    /// stretch of audio, nothing already proposed, and nothing sitting on an
    /// ordinary word. FluidAudio's own rescue path skips all three, which is
    /// why it altered 370 of 386 clips and is switched off in `rescorerConfig`.
    private static func acousticSpans(
        _ detections: [CtcKeywordSpotter.KeywordDetection], in text: String,
        timings: [TokenTiming], known: Set<String>, avoiding taken: [Range<String.Index>]
    ) -> [(range: Range<String.Index>, term: String, score: Float)] {
        let spoken = words(from: timings, in: text)
        let bare = { (s: Substring) in String(s).lowercased().filter(\.isLetter) }

        var out: [(range: Range<String.Index>, term: String, score: Float)] = []
        var perTerm: [String: Int] = [:]
        var claimedWords: Set<Int> = []
        for hit in detections.sorted(by: { $0.score > $1.score })
        where hit.score >= spotterFloor {
            guard perTerm[hit.term.text, default: 0] < spansPerTerm else { continue }

            // The word this detection sits on, plus a neighbour when it covers
            // most of one too — a split name is two words and one detection.
            //
            // Midpoint gating was too strict to be worth its precision: a
            // detection is a third of a second against word timings that are
            // approximate, and the best `Praisy` hit in one clip — the one
            // sitting on the name — covered no word midpoint at all and was
            // dropped, while two worse hits on other spans survived. Largest
            // overlap always yields a word, which is what a menu needs.
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
            // function word. `Praisy` decoded as "praise he" put its best hit
            // on "he", which the ordinary-word guard below then threw away —
            // so reach for the neighbour rather than give up.
            if covered.allSatisfy({ ordinary.contains(bare(text[spoken[$0].range])) }) {
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
            // "Versailles." replaced by "Vercel" takes the full stop with it,
            // and the sentence loses its end.
            var upper = spoken[last].range.upperBound
            while upper > spoken[last].range.lowerBound,
                  let before = text.index(upper, offsetBy: -1, limitedBy: text.startIndex),
                  !text[before].isLetter && !text[before].isNumber {
                upper = before
            }
            let range = spoken[first].range.lowerBound..<upper
            guard !range.isEmpty else { continue }
            let inside = text[range].split(whereSeparator: { !$0.isLetter })

            // Already written, already proposed, or every word ordinary.
            //
            // The third guard is about a *different* term: the spotter put
            // `Ollama` at -4.37 over the word "Mirza", which the decoder had
            // already got right. A word that is itself a vocabulary term is not
            // a mistake, whatever else was heard near it.
            guard !inside.contains(where: { bare($0) == hit.term.text.lowercased() }),
                  !inside.contains(where: { known.contains(bare($0)) }),
                  !taken.contains(where: { $0.overlaps(range) }),
                  inside.contains(where: { !ordinary.contains(bare($0)) })
            else { continue }
            claimedWords.formUnion(covered)
            perTerm[hit.term.text, default: 0] += 1
            out.append((range, hit.term.text, hit.score))
        }
        return out
    }

    // MARK: - Wider spans

    /// A term the decoder split across a word boundary, offered as the wider
    /// span as well as the word the rescorer settled on.
    ///
    /// The two compete inside FluidAudio and the shorter one wins on
    /// similarity, which is right when it is deciding and wrong when it is
    /// proposing: "praise he" is the whole of `Praisy` and "praise" is most of
    /// it, so every reading built from the shorter span leaves a word behind.
    /// Offered, never applied — a span this far out is exactly the kind only a
    /// sentence can settle.
    ///
    /// Both sources, not just the rescorer's. The clips this exists for are
    /// the ones where only the audio found anything: "praise his work" has no
    /// spelling near `Praisy` and arrives entirely from the spotter.
    private static func widerSpans(
        in text: String, anchors: [(range: Range<String.Index>, term: String)]
    ) -> [(range: Range<String.Index>, heard: String, term: String, canonical: String)] {
        var wider: [(range: Range<String.Index>, heard: String, term: String, canonical: String)] = []
        for (range, term) in anchors {
            guard !term.isEmpty else { continue }

            // The word after, and the word after that. A name the decoder split
            // lands as a run rather than a token: `Praisy` came out "praise he",
            // "praise his", "Prissy d".
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
            // independent: "praise his" is 0.45 from `Praisy` and 0.59 from
            // `Praisy's`, so testing the possessive only on spans that already
            // passed threw away the one that was right.
            //
            // The possessive is here because the term never carries it and the
            // speaker usually does. "praise his work" is `Praisy's work`, and
            // no span of the transcript spells that — it has to be built rather
            // than found.
            for stop in [range.upperBound] + ends {
                let phrase = String(text[range.lowerBound..<stop])
                guard !phrase.isEmpty else { continue }
                // A possessive owns the word after it, so a span that ends the
                // sentence cannot be one. Measured: `Praisy's` was offered at a
                // full stop — "it would be both praise and Praisy's." — and the
                // judge took it over the reading that was right.
                let ownsSomething = !phrase.contains(where: { ".?!".contains($0) })
                    && stop < text.endIndex
                for reading in ownsSomething ? [term, term + "'s"] : [term] {
                    guard phrase.lowercased() != reading.lowercased(),
                          gluedSimilarity(phrase, reading) >= widerSpanFloor,
                          !wider.contains(where: {
                              $0.range == range.lowerBound..<stop && $0.term == reading
                          })
                    else { continue }
                    wider.append((range.lowerBound..<stop, phrase, reading, term))
                }
            }
        }
        return wider
    }
}
