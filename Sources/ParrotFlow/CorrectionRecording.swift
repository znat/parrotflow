import Foundation

/// What a correction that runs against a term teaches, and to which term.
///
/// The app wrote one word and you put another back. What that says depends on
/// what you put:
///
/// - an ordinary word — `Vercel` back to `Versailles` — says nothing about a
///   term called Versailles and everything about where Vercel lives. It is a
///   **counter** under Vercel.
/// - another term — `Mik` back to `Mick` — says where Mick lives. It is a
///   **use** of Mick, with `heard:` set to the spelling it replaced. Nothing
///   is written under Mik: the two share a sound, and the sentence is Mick's
///   evidence, not evidence against Mik.
///
/// The second used to write both rows, and those are the rows that poisoned
/// the portraits: every sentence one member lived in was stored as a place the
/// other does not, so the loser's counter centre filled up with sentences
/// about its own group. See `docs/proposals/sound-groups.md`.
enum CorrectionRecording {

    /// One row to write in `vocabulary-uses.yaml`.
    enum Row: Equatable {
        /// A sentence the term lives in, and the spelling it replaced.
        case use(term: String, span: String, heard: String?)
        /// A sentence the term does not live in. `span` is the word that does.
        case counter(term: String, span: String)

        var term: String {
            switch self {
            case .use(let term, _, _), .counter(let term, _): return term
            }
        }
    }

    /// What one correction writes.
    ///
    /// Empty when the word that was written is not a term at all. That is the
    /// ordinary direction — an ordinary word corrected into a name — and the
    /// correction panel offers a rule for it instead.
    ///
    /// The same term on both sides is a capital or a possessive being fixed,
    /// and says nothing about where anything lives.
    static func rows(
        wrote written: String, put back: String, terms: [String]
    ) -> [Row] {
        guard let lost = term(named: written, in: terms) else { return [] }
        guard let right = term(named: back, in: terms) else {
            return [.counter(term: lost, span: back)]
        }
        guard right != lost else { return [] }
        return [.use(term: right, span: back, heard: written)]
    }

    /// Writes them. One row per call to `TermUses.record`, in order.
    ///
    /// Returns the rows that were written, which is fewer than it was given
    /// when the word does not stand in the sentence as a word — `TermUses`
    /// refuses those, and says so by writing nothing.
    @discardableResult
    static func apply(
        _ rows: [Row], said sentence: String, from source: TermUses.Use.Source = .correction
    ) throws -> [Row] {
        var written: [Row] = []
        for row in rows {
            guard TermUses.occurrence(of: span(of: row), in: sentence) != nil else { continue }
            switch row {
            case .use(let term, let span, let heard):
                try TermUses.record(
                    term: term, said: sentence, span: span, from: source, heard: heard
                )
            case .counter(let term, let span):
                try TermUses.record(
                    term: term, said: sentence, span: span, from: source, counter: true
                )
            }
            written.append(row)
        }
        return written
    }

    static func span(of row: Row) -> String {
        switch row {
        case .use(_, let span, _), .counter(_, let span): return span
        }
    }

    /// The vocabulary term this word is, ignoring case and any possessive.
    static func term(named word: String, in terms: [String]) -> String? {
        var bare = word.trimmingCharacters(in: .whitespaces)
        if let mine = Vocabulary.possessive(in: bare) {
            bare = String(bare.dropLast(mine.suffix.count))
        }
        bare = bare.trimmingCharacters(in: .punctuationCharacters)
        guard !bare.isEmpty else { return nil }
        return terms.first { $0.caseInsensitiveCompare(bare) == .orderedSame }
    }
}
