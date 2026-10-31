import Foundation
import NaturalLanguage

/// What kind of name a word is, read by `NLTagger`.
enum NamePlace {

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
}
