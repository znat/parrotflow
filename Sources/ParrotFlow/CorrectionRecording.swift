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
        wrote written: String, put back: String, terms: [String],
        kinds: [String: Config.Vocabulary.Term] = [:]
    ) -> [Row] {
        guard let lost = term(named: written, in: terms) else { return [] }
        guard let right = term(named: back, in: terms) else {
            // A name with no term yet is not an ordinary word, and a counter
            // under the name it replaced is the poisoning this model exists to
            // end: five sentences about a third person filed as places the
            // second one does not live. It is a rendering to learn instead —
            // see `learns`.
            if learns(wrote: written, put: back, in: kinds) != nil { return [] }
            return [.counter(term: lost, span: back)]
        }
        guard right != lost else { return [] }
        return [.use(term: right, span: back, heard: written)]
    }

    /// The term a correction onto a new name asks to create, and its kind.
    ///
    /// `Anna` corrected to `Annah` where only `Anna` is a term: the word put
    /// back is a name the vocabulary has never seen. The ordinary correction
    /// path already knows what to do with that — write the rendering, create
    /// the term, record the sentence as a use — and it never got the chance,
    /// because the counter branch took every correction whose left side was a
    /// term. Measured on decoded audio, 2026-09-10: five sentences about a
    /// third person became five counters under the second, and the pooled
    /// plain centre then scored 0.945 on a sentence that was hers.
    ///
    /// The rendering it writes — `heard: Anna` under `Annah` — is not a
    /// substitution rule, because `Anna` is another term's spelling. It opens
    /// the group, which is the only thing that lets the new name be proposed
    /// at all.
    static func learns(
        wrote written: String, put back: String, in terms: [String: Config.Vocabulary.Term]
    ) -> (name: String, kind: WordKind)? {
        guard let lost = term(named: written, in: Array(terms.keys)),
              term(named: back, in: Array(terms.keys)) == nil
        else { return nil }
        guard case .create(let name, let kind) = picked(back, proposedBy: lost, in: terms)
        else { return nil }
        // A person only. On the pill you are choosing between names offered
        // for one sound, and a place or a company picked there is a name you
        // chose. A correction is the other direction — a term taken back out —
        // and `Vercel` corrected to `Versailles` is the counter-example the
        // portrait is built from, not a new member of the group.
        guard kind == .person else { return nil }
        return (name, kind)
    }

    /// What picking a word on the pill means.
    enum Picked: Equatable {
        /// A term already: the sentence is a use of it.
        case use(term: String)
        /// A name with no term yet. Every name is a term, so it is written as
        /// one — with the kind the tagger read and no pronunciation, because
        /// nothing was misheard — and the sentence is a use of it.
        case create(name: String, kind: WordKind)
        /// An ordinary word: a counter under the term that was proposed, which
        /// is the sentence plain owns.
        case counter(term: String)
    }

    /// Which of the three this answer is.
    ///
    /// A person the recogniser spells right never gets a term the ordinary
    /// way: nothing is ever corrected, so nothing ever creates one, and every
    /// sentence about them piles up as a counter under somebody else's name.
    /// The pill is the one place that can tell — the word was picked over a
    /// name, and the tagger or the proposing term says it is a name too.
    static func picked(
        _ word: String, proposedBy term: String, in terms: [String: Config.Vocabulary.Term]
    ) -> Picked {
        if let already = self.term(named: word, in: Array(terms.keys)) {
            return .use(term: already)
        }
        let bare = word.trimmingCharacters(in: .punctuationCharacters)
        guard !bare.isEmpty else { return .counter(term: term) }
        // What the tagger read, when it read a name at all. A place or an
        // organization picked here is a term too, and labelling it `person`
        // would put a guess in the file under the name of a fact.
        let read = NamePlace.kind(of: bare)
        if read != .word { return .create(name: bare, kind: read) }
        // The company it keeps: a term that names a person was proposed over
        // this word, so the word sounds like a person's name. The tagger has
        // nothing to say about it, so `person` is the only kind on offer.
        if terms[term]?.kind == .person { return .create(name: bare, kind: .person) }
        return .counter(term: term)
    }

    /// The two group members standing in this sentence, when there are two.
    ///
    /// A sentence naming two members of one group belongs to neither, and
    /// storing it under either one teaches the wrong thing about both. The
    /// rival clip cuts the window at the other spelling, and what survives
    /// between them is still the sentence: "So I tried again with Erik the
    /// musician and Eric the software engineer." was kept as a counter under
    /// Erik on 2026-09-10, and every later "Eric the musician" was refused,
    /// 0.80 against 0.93 and 0.90 against 0.92.
    ///
    /// Nil when fewer than two members stand there, which is every ordinary
    /// correction.
    static func blocked(
        _ sentence: String, term: String, in groups: [SoundGroup.Group]
    ) -> [String]? {
        let standing = SoundGroup.standing(in: sentence, of: term, in: groups)
        return standing.count > 1 ? standing : nil
    }

    /// Writes them. One row per call to `TermUses.record`, in order.
    ///
    /// Returns the rows that were written, which is fewer than it was given
    /// when the word does not stand in the sentence as a word — `TermUses`
    /// refuses those, and says so by writing nothing.
    @discardableResult
    static func apply(
        _ rows: [Row], said sentence: String, from source: TermUses.Use.Source = .correction,
        near word: Int? = nil, blocking groups: [SoundGroup.Group] = []
    ) throws -> [Row] {
        var written: [Row] = []
        for row in rows {
            if let two = blocked(sentence, term: row.term, in: groups) {
                Log.write("uses: \"\(TermUses.narrowed(sentence, to: span(of: row), near: word))\""
                    + " names both \(two.joined(separator: " and ")) — it says nothing about"
                    + " either, so nothing is recorded")
                continue
            }
            guard TermUses.occurrence(of: span(of: row), in: sentence) != nil else { continue }
            switch row {
            case .use(let term, let span, let heard):
                try TermUses.record(
                    term: term, said: sentence, span: span, from: source, heard: heard,
                    near: word
                )
            case .counter(let term, let span):
                try TermUses.record(
                    term: term, said: sentence, span: span, from: source, counter: true,
                    near: word
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
