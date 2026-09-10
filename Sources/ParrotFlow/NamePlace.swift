import Foundation
import NaturalLanguage

/// Is this place one name against another?
///
/// The slot test asks whether the term can stand where the word was heard, and
/// it answers by comparing vectors: a term is unknown to the tokenizer by
/// construction, and an ordinary word is not, so the heard word always wins by
/// a margin that says nothing about the sentence. That is the point when the
/// heard word is ordinary — `versus` really does belong where `Vercel` was
/// proposed.
///
/// It is not the point when the heard word is a name too. Measured on the
/// live app, 2026-09-10: `Eric` against the term `Erik` gives a gap of −0.254
/// in "Eric plays the piano.", −0.253 in "Eric plays the guitar." and −0.257
/// in "Eric is a musician." — the same refusal three times, because `Eric` is
/// in the tokenizer and `Erik` is not. The place was settled before the
/// portrait or the pill could see it, so a new name could never start.
///
/// Three tells, any one of which makes it a name against a name:
///
/// - the term says so: `kind: person` in `vocabulary.yaml`;
/// - `NLTagger` reads the heard word as a personal name;
/// - the heard word is a `heard:` rendering somebody wrote down. A rendering
///   is a spelling of a name by definition.
enum NamePlace {

    /// Whether the slot test has to stand aside at this place.
    static func bothNames(
        heard: String, term: String, in terms: [String: Config.Vocabulary.Term]
    ) -> Bool {
        let bare = word(of: term)
        let named = terms.first { $0.key.caseInsensitiveCompare(bare) == .orderedSame }
        if named?.value.kind == .person { return true }
        if renderings(of: heard, in: terms) { return true }
        return isPersonalName(word(of: heard))
    }

    /// A `heard:` rendering of any term, matched without case.
    private static func renderings(
        of heard: String, in terms: [String: Config.Vocabulary.Term]
    ) -> Bool {
        let needle = word(of: heard)
        return terms.values.contains { entry in
            entry.heard.contains { $0.caseInsensitiveCompare(needle) == .orderedSame }
        }
    }

    static func isPersonalName(_ word: String) -> Bool {
        kind(of: word) == .person
    }

    /// What kind of name `NLTagger` reads this word as, or `.word` when it
    /// reads no name at all.
    ///
    /// In a frame, not bare: the tagger reads a lone word as a noun whatever
    /// it is. The frame names nobody and nowhere, so what comes back is about
    /// the word — `Sarah` is a person in it, `Versailles` a place, `Microsoft`
    /// an organization, and `Cancel`, `Merge`, `Price`, `The` and `Match` are
    /// none of the three.
    static func kind(of word: String) -> WordKind {
        let bare = String(word.prefix { $0.isLetter || $0 == "-" || $0 == "'" })
        guard bare.count > 1, bare.first?.isUppercase == true else { return .word }
        let framed = "We talked about \(bare) again yesterday."
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = framed
        tagger.setLanguage(.english, range: framed.startIndex ..< framed.endIndex)
        guard let at = framed.range(of: bare) else { return .word }
        let tag = tagger.tag(at: at.lowerBound, unit: .word, scheme: .nameTypeOrLexicalClass)
            .0?.rawValue
        return WordKind.from(tag: tag)
    }

    /// The first word of a span, without its possessive or its punctuation.
    private static func word(of span: String) -> String {
        var bare = span.trimmingCharacters(in: .whitespaces)
        if let mine = Vocabulary.possessive(in: bare) {
            bare = String(bare.dropLast(mine.suffix.count))
        }
        bare = bare.trimmingCharacters(in: .punctuationCharacters)
        return String(bare.prefix { !$0.isWhitespace })
    }
}
