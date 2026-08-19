import Foundation
import NaturalLanguage

/// What kind of word each word is, for a stage that has to decide about one.
///
/// Handed to `returns: json` transforms as `tokens`, beside the transcript. The
/// point is not analysis — nothing here builds a tree — it is that one question
/// keeps coming up and cannot be answered from a string: **is this capital the
/// decoder starting a clip, or the speaker naming somebody?**
///
/// `join` asked it first. Lowering the case of anything the dictionary knew
/// turned "I called Sarah" into "I called sarah". A closed list of function
/// words was the workaround and it left "the meeting is Postponed at noon"
/// unfixed, because an open-class word cannot be judged by spelling.
///
/// `.nameTypeOrLexicalClass` answers it in one pass. Measured on clips as a
/// stage actually receives them — standalone, capitalised, one sentence:
///
///     Postponed.  Verb            Sarah.      PersonalName
///     Considered. Verb            Vercel.     PlaceName
///     On.         Preposition     Tasmeen.    Noun
///
/// 0.29 ms for a sentence, 0.97 ms for two hundred words. A tenth of what
/// starting the `python3` that receives it costs, so it is not conditional.
enum Tagger {

    struct Token: Encodable {
        /// Character offset into the text this token describes, and its length.
        /// Swift counts graphemes and Python counts code points; they differ
        /// only on combining sequences, which dictation does not produce.
        let at: Int
        let len: Int
        let text: String
        /// `Verb`, `Noun`, `PersonalName`, `PlaceName`, `OrganizationName`,
        /// `Determiner`, `Number`… one scheme, because the question "is this a
        /// name" and the question "what part of speech" have one answer.
        let tag: String
        /// The dictionary form. Absent for a word no dictionary knows, which is
        /// itself the signal for a term that may want a vocabulary entry.
        let lemma: String?
    }

    /// Every word in `text`, tagged. `language` comes from the pipeline scope
    /// rather than being detected again — two sources for one field is how they
    /// disagree, and the scope already resolved it.
    static func tokens(in text: String, language: String?) -> [Token] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        tagger.string = text
        if let language, !language.isEmpty {
            tagger.setLanguage(NLLanguage(rawValue: language),
                               range: text.startIndex..<text.endIndex)
        }

        var out: [Token] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word,
            scheme: .nameTypeOrLexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
            out.append(Token(
                at: text.distance(from: text.startIndex, to: range.lowerBound),
                len: text.distance(from: range.lowerBound, to: range.upperBound),
                text: String(text[range]),
                tag: tag?.rawValue ?? "Other",
                lemma: lemma?.rawValue
            ))
            return true
        }
        return out
    }
}
