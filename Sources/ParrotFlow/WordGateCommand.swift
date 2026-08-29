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
        // The decision comes from the shipped test. The two verdicts above it
        // are read from the same lists for the report, so a set can say which
        // half moved — they do not compute the answer.
        let forms = letters == letters.uppercased()
            ? [letters.lowercased()] : [letters, letters.lowercased()]
        print("spell      \(forms.contains { Replacements.isRealWord($0) } ? "known" : "unknown")")
        switch WordPieces.knows(letters) {
        case .some(true):  print("wordpiece  known")
        case .some(false): print("wordpiece  unknown")
        case .none:        print("wordpiece  unavailable")
        }
        print("gate       \(Vocabulary.unseenWord(letters) ? "auto-apply" : "judge")")
        return 0
    }
}
