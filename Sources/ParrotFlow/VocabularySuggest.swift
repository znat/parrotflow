import Foundation

/// Which words in a sentence look like they want a vocabulary entry.
///
/// The correction panel opens on the sentence you just dictated. Asking you to
/// find the wrong word yourself is asking you to re-read it; this proposes the
/// rows instead, and you fill in the right-hand side.
///
/// **One signal, not two.** A word the dictionary does not know. Measured over
/// the 56 distinct sentences of `tests/judge-cases.yaml` — 1166 words, 17 of
/// which genuinely needed fixing:
///
///     arm                     found   rows per sentence
///     dictionary              12/17          0.4
///     no lemma                12/17          1.4
///     dictionary + no lemma   12/17          0.4
///     dictionary + name tag   12/17          0.9
///
/// `NLTagger` adds nothing. Every word it tags as a Verb is a word the
/// dictionary knows, so "has no lemma" and "the dictionary does not know it"
/// are the same answer arrived at twice. On its own the lemma is three times
/// noisier for the same 12. The tag is still read, but only to propose the
/// `kind` column — never to decide whether there is a row at all.
///
/// **What it cannot find.** Five misses. `Prissy` and `cloud` are real words,
/// so no dictionary can flag them. `red rock` and `Matthew at` are two words,
/// and a row holds one span — widen the left-hand field by typing, which is why
/// that field is editable rather than fixed.
///
/// 33 of the 56 sentences propose nothing, 22 propose one row and 1 proposes
/// two. It cannot flood the panel.
enum VocabularySuggest {

    struct Row: Equatable {
        /// The word as the decoder wrote it, without the punctuation around it.
        var heard: String
        var kind: WordKind
    }

    static func rows(in sentence: String, language: String? = nil) -> [Row] {
        var seen = Set<String>()
        var rows: [Row] = []
        for token in Tagger.tokens(in: sentence, language: language) {
            let word = token.text
            guard word.count > 1, word.contains(where: \.isLetter) else { continue }
            guard !Replacements.isRealWord(word) else { continue }
            guard seen.insert(word.lowercased()).inserted else { continue }
            rows.append(Row(heard: word, kind: .from(tag: token.tag)))
        }
        return rows
    }
}
