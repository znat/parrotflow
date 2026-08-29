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
/// Name the term and the whole gate answers instead, about that pair:
///
///     ParrotFlow --word-gate "Mirza's" Mirza
///     possessive dropped
///     gate       judge
///
/// One condition of the gate is not about a word at all. A possessive the
/// heard text carries and the term does not is a question about the sentence,
/// so it needs both halves of the proposal — see `Vocabulary.dropsPossessive`.
///
/// No audio and no model either way. The pair form fixes the scores so the
/// term wins, because the acoustic half is not what it is asking; a proposal
/// whose term loses on sound never reaches these conditions.
enum WordGateCommand {
    static func run(word: String, term: String? = nil) -> Int32 {
        if let term, !term.isEmpty { return pair(heard: word, term: term) }

        let letters = String(word.filter { $0.isLetter })
        guard !letters.isEmpty else {
            print("usage: ParrotFlow --word-gate <word> [term]")
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

    /// The gate on one proposal, from the shipped `Vocabulary.autoApplies`.
    ///
    /// The two lists are not printed here. They are not consulted at all on a
    /// span the gate matches glued — `"Matthew at"` — so printing them would
    /// report a lookup that decided nothing.
    private static func pair(heard: String, term: String) -> Int32 {
        let drops = Vocabulary.dropsPossessive(heard: heard, term: term)
        print("possessive \(drops ? "dropped" : "kept")")
        let applies = Vocabulary.autoApplies(
            heard: heard, term: term, heardScore: -1, termScore: 0
        )
        print("gate       \(applies ? "auto-apply" : "judge")")
        return 0
    }
}
