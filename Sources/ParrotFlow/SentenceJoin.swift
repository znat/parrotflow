import Foundation
import NaturalLanguage

/// Where a pause may have cut a sentence, and how the word after it is written
/// once the mark is gone.
///
/// The transcriber writes a period wherever you stop for breath, and
/// capitalises the word after it. `boundaries` finds those places for
/// `ReadingsField`, which scores each with `SentenceReadings` and hands the
/// scores to the `sentence_repair` transform. The transform decides. Nothing
/// here rewrites a transcript.
///
/// `written` is the lowercasing rule. `VocabularyPass` asks it about a word a
/// substitution left mid-sentence.
@available(macOS 14, *)
enum SentenceJoin {

    /// The reading with the highest per-token score, or nil if there is none.
    ///
    /// First past the post over the order `SentenceReadings.readings` builds —
    /// the marks, then the join — so an exact tie leaves the boundary alone.
    static func winner(of scores: [SentenceReadings.Score]) -> SentenceReadings.Score? {
        scores.reduce(nil) { best, score in
            guard let best else { return score }
            return score.mean > best.mean ? score : best
        }
    }

    /// One boundary: where the mark is, which mark it is, and the word after
    /// it.
    struct Boundary {
        let at: String.Index
        let mark: Character
        let next: Range<String.Index>
    }

    /// Marks that only start a boundary in front of a capital.
    ///
    /// Empty. `word? lowercase` was always a boundary: of 19 such lines in the
    /// user's dictation, 7 hold a spurious mark and 12 a real question, so the
    /// reading has to decide and no rule can. `word. lowercase` was left alone
    /// as an unmeasured shape, and has now been measured: 26 of them over 9399
    /// dictations, none of which is a sentence ending — an ending carries a
    /// capital — and none of which is an abbreviation. Read, 7 join and the
    /// other 19 are left as decoded.
    ///
    /// What the capital bought for free was the abbreviations, and
    /// `refusing:` buys them again.
    static let capitalOnly: Set<Character> = []

    /// Where a boundary is looked for: the sentence enders in the configured
    /// mark list. The rest of the list — the comma — is a reading tried at a
    /// boundary, not a place to find one.
    static func scanned(_ marks: [String]) -> Set<Character> {
        Set(marks.filter { SentenceReadings.enders.contains($0) }.compactMap(\.first))
    }

    /// Tags a capital must survive. A name stays a name once the mark goes.
    static let names: Set<String> = ["PersonalName", "PlaceName", "OrganizationName"]

    /// The tagger reads the dictation's language. Asked in English, `NLTagger`
    /// gives no lemma for most French words, and "no lemma" is what this rule
    /// reads as a name — so a joined French boundary kept its capital.
    static func tag(for language: String) -> NLLanguage {
        language == "fr" ? .french : .english
    }

    /// The languages the boundary is read in.
    ///
    /// English and French. The reason this was English alone — "the readings
    /// are scored by an English base model" — went when ModernBERT left; the
    /// model is Qwen3 and it is multilingual. Measured over 234 French
    /// boundaries, 103 real periods mined from real dictation and 131 cuts made
    /// by inserting one: AUC 0.968 against 0.984 in English, 91% of cuts
    /// repaired, and 6 false joins of which four are repairs the mining
    /// mislabelled — about 2 per 100 real periods.
    static let languages: Set<String> = ["en", "fr"]

    // MARK: - Finding the boundaries

    /// Every place one of `marks` is followed by a word.
    ///
    /// Four things that look like a boundary and are not. A mark inside a run
    /// of them is an ellipsis or a stutter. A mark after a single letter is an
    /// initial — "J. Smith". A mark after anything but a letter or a digit is
    /// closing something rather than ending a sentence. And a word in
    /// `refusing` is an abbreviation, which carries a full stop that ends no
    /// sentence — see `Config.defaultAbbreviations`.
    static func boundaries(
        in text: String, scanning marks: Set<Character>, refusing: Set<String> = []
    ) -> [Boundary] {
        var found: [Boundary] = []
        var cursor = text.startIndex
        while let at = text[cursor...].firstIndex(where: { marks.contains($0) }) {
            let mark = text[at]
            cursor = text.index(after: at)
            guard at > text.startIndex, cursor < text.endIndex, text[cursor] != mark else {
                continue
            }
            // French sets a space before `?` — "travailler ?" — so the word is
            // looked for past it. Without this every French question boundary
            // is invisible and nothing says so. `!` is in no mark set, in
            // either language, so it is not scanned here and not a boundary.
            let ahead = text[..<at].reversed().drop { $0.isWhitespace }
            let word = ahead.prefix { $0.isLetter || $0.isNumber }
            guard word.count > 1 else { continue }
            guard !refusing.contains(String(word.reversed()).lowercased()) else { continue }

            var start = cursor
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
            guard start > cursor, start < text.endIndex, text[start].isLetter else { continue }
            guard text[start].isUppercase || !capitalOnly.contains(mark) else { continue }
            // The next word can carry the mark of the boundary after it —
            // "…the format. Right? We have". The word stops before that mark,
            // so the scan reaches it instead of stepping over it.
            var end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            while end > start, marks.contains(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            found.append(Boundary(at: at, mark: mark, next: start..<end))
            cursor = end
        }
        return found
    }

    // MARK: - The capital, once the period is gone

    /// The next word as it should be written with no period in front of it.
    ///
    /// Not every capital after a period is there because of the period. "I
    /// will ask him. Nathan knows the answer" must not become "ask him nathan
    /// knows", so the rule asks for a reason to lowercase rather than a reason
    /// to keep. Four say keep:
    ///
    ///   - `I`, and every contraction that starts with it.
    ///   - a word written in capitals throughout — `API`, `CI`.
    ///   - `PersonalName`, `PlaceName` or `OrganizationName` from `NLTagger`.
    ///   - a word `NLTagger` gives no lemma for. The lexicon does not know it,
    ///     and a capitalised word the lexicon has never seen is a name it has
    ///     not been told about. This is what catches `ParrotFlow`, which the
    ///     tagger calls a plain `Noun`.
    ///
    /// A vocabulary term is asked before any of that. Those are exactly the
    /// words this speaker uses and the lexicon does not, and a term that is
    /// also an English word — `Compass` — is the one case the lemma rule
    /// cannot see.
    ///
    /// Measured over `tests/sentence-case-cases.json` by
    /// `scripts/check-sentence-case.sh`. No model, so it runs in CI.
    ///
    /// `joined` is the text with this period already removed, and `at` is
    /// where the word starts in it. The word is tagged mid-sentence rather
    /// than at the head of one: with the period still in place the same set
    /// scored 20 of its first 24 cases, and without it 21.
    static func written(
        _ word: String, in joined: String, at offset: Int, terms: [String],
        language: String = "en"
    ) -> String {
        let bare = String(word.prefix { $0.isLetter })
        guard let first = word.first, first.isUppercase, !bare.isEmpty else { return word }
        guard bare != "I", bare.count == 1 || bare != bare.uppercased() else { return word }
        guard !terms.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) else {
            return word
        }
        guard let from = joined.index(
            joined.startIndex, offsetBy: offset, limitedBy: joined.endIndex
        ) else { return word }

        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        tagger.string = joined
        tagger.setLanguage(Self.tag(for: language), range: joined.startIndex..<joined.endIndex)
        let tag = tagger.tag(at: from, unit: .word, scheme: .nameTypeOrLexicalClass).0?.rawValue
        guard !Self.names.contains(tag ?? "") else { return word }
        let lemma = tagger.tag(at: from, unit: .word, scheme: .lemma).0?.rawValue ?? ""
        guard !lemma.isEmpty else { return word }
        return word.prefix(1).lowercased() + word.dropFirst()
    }
}

