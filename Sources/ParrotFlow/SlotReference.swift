import Foundation

/// Does the vocabulary term belong in this position, or does the heard word?
///
/// The six tests in `Vocabulary` read spelling and grammar. None of them reads
/// what the sentence is about, so the pass writes `Ghostty` over `ghostly` in
/// "the old house looked ghostly in the fog" and over `Ghostly` in "I work with
/// Claude Code in Ghostly all day". Same heard word, same term, opposite right
/// answers. Only the sentence separates them.
///
/// This asks ModernBERT for the ten words it expects in the slot, then measures
/// both readings against them with `WordVectors`. Negative means the heard word
/// fits better.
///
/// **It only ever refuses.** Across every measurement it never authorised a
/// rewrite the stage had not already made, and its widest write is +0.7 of the
/// spread while its vetoes reach -3.4. A term is unknown to the tokenizer by
/// construction, so its vector is built from fragments and sits further from any
/// centre than a real word's; the comparison is not symmetric and cannot be made
/// to write. `TermPortrait` is the half that authorises.
///
/// Measured on 59 hand-labelled proposals and on 35 more from fresh dictation,
/// at `floor`: no correct rewrite refused, no ordinary word overwritten.
@available(macOS 14, *)
enum SlotReference {

    /// How far the heard word must win by before the rewrite is refused.
    ///
    /// The raw difference of two cosines, not divided by anything. Dividing by
    /// the spread of the ten words looks like it should help and does the
    /// opposite: a sentence holding a rare name makes the ten words collapse
    /// together, the spread goes to 0.002, and the ratio explodes on exactly
    /// the cases that should be written.
    ///
    /// 0.20 holds on three sets, two of them chosen after it was fixed.
    /// Ordinary words sit at -0.30 to -0.43 and correct rewrites at -0.02 to
    /// -0.18, and nothing lands between.
    static let floor = 0.20

    /// How many words the reference is built from, and how deep to look for
    /// them. Ten is what every measurement used.
    static let fillers = 10
    private static let depth = 60

    enum Failure: LocalizedError {
        case noSlot(String)

        var errorDescription: String? {
            switch self {
            case .noSlot(let word): return "\"\(word)\" is not in the sentence"
            }
        }
    }

    /// The ten words the mask expects, in order.
    ///
    /// Alphabetic only, and one per spelling: ModernBERT offers `GitHub` and
    /// `github` for the same slot, and counting both narrows the reference to
    /// one word wearing two hats.
    static func expected(left: String, right: String) async throws -> [String] {
        let probe = try await SentenceProbe.load()
        let slot = try probe.at(left: left, right: right)
        var words: [String] = []
        var seen = Set<String>()
        for prediction in slot.top(depth) {
            let word = prediction.word.trimmingCharacters(in: .whitespaces)
            guard word.allSatisfy({ $0.isLetter }), !word.isEmpty else { continue }
            guard seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
            if words.count == fillers { break }
        }
        return words
    }

    /// How much better the term fits this slot than the heard word.
    ///
    /// Below `-floor`, refuse the rewrite. The sign is what carries: the size
    /// says how far apart the two readings are, not how sure the answer is.
    static func gap(term: String, heard: String, in sentence: String) async throws -> Double {
        guard let found = sentence.range(of: heard) else { throw Failure.noSlot(heard) }
        return try await gap(term: term, heard: heard, at: found, in: sentence)
    }

    /// The same, about one position rather than the first one that matches.
    ///
    /// A sentence can hold the word twice — "deploying apps on Versailles while
    /// visiting the Versailles castle" — and the whole point of reading the
    /// sentence is that the two get different answers. Searching for the word
    /// scored both at the first one, so the second was decided by a slot it was
    /// not in.
    static func gap(
        term: String, heard: String, at found: Range<String.Index>, in sentence: String
    ) async throws -> Double {
        let left = String(sentence[sentence.startIndex ..< found.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let right = String(sentence[found.upperBound...])
        return try await gap(term: term, heard: heard, left: left, right: right)
    }

    /// `left` ends on a word with no trailing space, `right` carries its own
    /// leading space — the shape `SentenceProbe` reads.
    static func gap(
        term: String, heard: String, left: String, right: String
    ) async throws -> Double {
        let words = try await expected(left: left, right: right)
        guard words.count >= 3 else { return 0 }

        var sum = [Double](repeating: 0, count: 0)
        for word in words {
            let vector = try await WordVectors.shared.vector(
                .word, of: word, in: sentence(left: left, word: word, right: right)
            )
            if sum.isEmpty { sum = [Double](repeating: 0, count: vector.count) }
            guard sum.count == vector.count else { continue }
            for i in vector.indices { sum[i] += Double(vector[i]) }
        }
        let length = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return 0 }
        let centre = sum.map { Float($0 / length) }

        let ofTerm = try await WordVectors.shared.vector(
            .word, of: term, in: sentence(left: left, word: term, right: right)
        )
        let ofHeard = try await WordVectors.shared.vector(
            .word, of: heard, in: sentence(left: left, word: heard, right: right)
        )
        return WordVectors.cosine(ofTerm, centre) - WordVectors.cosine(ofHeard, centre)
    }

    /// What the model is given, with the slot filled.
    ///
    /// `right` already carries its leading space, so only the left join needs
    /// one, and an empty left needs none.
    private static func sentence(left: String, word: String, right: String) -> String {
        left.isEmpty ? word + right : left + " " + word + right
    }
}
