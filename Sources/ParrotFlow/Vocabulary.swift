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

    /// Whether the heard word carries an apostrophe the term does not.
    ///
    /// `bare` is letters only, so `wouldn't` is looked up as `wouldnt` — a form
    /// neither list has ever seen, where `wouldn't` itself is an ordinary
    /// English word. The apostrophe walks a contraction straight past both
    /// lists, exactly as it did a possessive. Measured on the shipped binary:
    /// 9 of 14 common contractions read `auto-apply`, and the 5 that do not
    /// survive by accident, because their stripped form is a word of its own —
    /// `cant`, `wont`, `dont`, `its`, `lets`.
    ///
    /// Asked here and not in `SlotGate`, because the slot is never consulted
    /// on a word the free tier has already decided: `I wouldn't do that` reads
    /// slot `Verb`, which the gate blocks, and the word was written anyway.
    ///
    /// A rule, not a threshold, and the same rule `dropsPossessive` is. Writing
    /// a name over `wouldn't` changes what the sentence says, in every
    /// sentence. It routes rather than refuses: the judge reads the sentence.
    static func dropsApostrophe(heard: String, term: String) -> Bool {
        inner(in: heard) && !inner(in: term)
    }

    /// An apostrophe with a letter on each side. A quoted word carries one at
    /// an end, and that says nothing about the word itself.
    private static func inner(in word: String) -> Bool {
        let marks: Set<Character> = ["'", "\u{2019}"]
        let letters = Array(word)
        return letters.indices.contains { i in
            marks.contains(letters[i]) && i > 0 && i < letters.count - 1
                && letters[i - 1].isLetter && letters[i + 1].isLetter
        }
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
        return autoApplies(heard: heard, term: term)
    }

    /// The same gate with the one line that reads the audio taken out.
    ///
    /// Every rule above is about spelling: a span that glues to the term, a
    /// possessive the term would drop, an apostrophe, and the two word lists.
    /// One line is not — `termScore > heardScore`, the CTC scores — and a
    /// proposal that reaches this stage from a spelling or from a sound has
    /// neither number.
    ///
    /// **That line has never been measured.** `scripts/check-slot-gate.sh`
    /// scores this gate on the 50 cases of `tests/judge-cases.yaml` by passing
    /// `heardScore: -1, termScore: 0` — two constants chosen so the guard is
    /// always true. So the 47/50 and the zero errors behind this whole tier
    /// were measured on exactly this function, with no audio in them at all.
    /// Leaving the line out here loses no evidence, because there is none.
    static func autoApplies(heard: String, term: String) -> Bool {
        // A possessive both sides carry is taken off both before anything is
        // looked up.
        //
        // The word test below is on letters only, so `Sarah's` is looked up as
        // `Sarahs` — a form no dictionary can contain. Both lists answer
        // "unknown" to a question neither was asked, and an ordinary name is
        // overwritten. Measured: `sarahs`, `mirzas` and `precys` are all
        // unknown to both lists; `sarah` is known to the tokenizer and `mirza`
        // to both, and only `precy` is genuinely new.
        //
        // Only when both carry one. A reading that takes a possessive away is
        // a different proposal, and `dropsPossessive` below still has to see
        // it.
        var heard = heard, term = term
        if let left = possessive(in: heard), let right = possessive(in: term),
           !left.stem.isEmpty, !right.stem.isEmpty {
            heard = left.stem
            term = right.stem
        }
        let letters = heard.filter { $0.isLetter || $0.isWhitespace }
        if letters.contains(" ") { return glues(heard: heard, term: term) }
        let bare = String(letters)
        guard !bare.isEmpty else { return false }
        guard !dropsPossessive(heard: heard, term: term) else { return false }
        guard !dropsApostrophe(heard: heard, term: term) else { return false }
        return unseenWord(bare)
    }

    /// A term the decoder split into words: `red crawl` for `Redcrawl`.
    ///
    /// Same phonemes, a space in the middle, so no word list can be asked about
    /// it — both halves are ordinary words. It is matched glued instead.
    ///
    /// True whenever the glued form is the term, which is also true when the
    /// glued form is an ordinary English phrase: `better stack` is `BetterStack`
    /// by this test and a stack that is better in every sentence anybody says.
    /// `VocabularyJudge.settle` is where that costs nothing and where it does.
    static func glues(heard: String, term: String) -> Bool {
        var heard = heard, term = term
        if let left = possessive(in: heard), let right = possessive(in: term),
           !left.stem.isEmpty, !right.stem.isEmpty {
            heard = left.stem
            term = right.stem
        }
        let letters = heard.filter { $0.isLetter || $0.isWhitespace }
        guard letters.contains(" ") else { return false }
        let glued = letters.replacingOccurrences(of: " ", with: "").lowercased()
        return glued == term.lowercased()
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
    /// route: the proposal is not refused, it is left to the tests that read
    /// the sentence.
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

    func slotGate() async -> SlotGate? {
        if let loadedSlotGate { return loadedSlotGate }
        guard !slotGateFailed, SentenceModel.isCached else { return nil }
        do {
            loadedSlotGate = SlotGate(probe: try await SentenceProbe.load())
        } catch {
            slotGateFailed = true
            Log.write("vocabulary: no slot gate (\(error.localizedDescription));"
                + " the sentence decides, or nothing does")
        }
        return loadedSlotGate
    }

}
