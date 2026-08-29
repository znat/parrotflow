import Foundation

/// Would this word be overwritten by a vocabulary term without anything asking?
///
///     ParrotFlow --word-gate Frederick
///     spell      unknown
///     wordpiece  known
///     gate       judge
///
/// The two word lists behind `Vocabulary.autoApplies`, and the decision they
/// reach together. Both verdicts are printed and not just the decision: a word
/// can reach `judge` from either side, and a set that only read the last line
/// would pass while testing the wrong half. This is the entry point
/// `scripts/check-word-gate.sh` scores, so the set runs against the shipped
/// lists rather than a copy of them.
///
/// No audio, no model, no scores. The gate's other conditions — the term must
/// beat what was heard, a split compound is matched glued — are about one
/// proposal; these two are about one word.
enum WordGateCommand {
    static func run(word: String) -> Int32 {
        let letters = String(word.filter { $0.isLetter })
        guard !letters.isEmpty else {
            print("usage: ParrotFlow --word-gate <word>")
            return 2
        }
        let forms = letters == letters.uppercased()
            ? [letters.lowercased()] : [letters, letters.lowercased()]
        let spellKnows = forms.contains { Replacements.isRealWord($0) }
        let listKnows = WordPieces.knows(letters)

        print("spell      \(spellKnows ? "known" : "unknown")")
        switch listKnows {
        case .some(true):  print("wordpiece  known")
        case .some(false): print("wordpiece  unknown")
        case .none:        print("wordpiece  unavailable")
        }
        print("gate       \(!spellKnows && listKnows == false ? "auto-apply" : "judge")")
        return 0
    }
}
