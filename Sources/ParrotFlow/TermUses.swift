import Foundation
import Yams

/// The sentences a term has been confirmed in, and where it sat in each.
///
/// A term's portrait is built from these: the mean of the context vectors,
/// each sentence with the term itself removed. It says what kind of sentence
/// the term appears in, which is the one thing the six shipped tests cannot
/// read.
///
/// **Sentences, not vectors.** A vector of 1024 numbers is unreadable and does
/// not survive a change of model, and both models here are expected to change.
/// A sentence is recomputed. It also lets the user see, correct or delete
/// whatever taught a term.
///
/// Its own file, not `vocabulary.yaml`. That one is hand-edited, and a term
/// with eight sentences under it would bury the list it exists to hold.
enum TermUses {

    /// One confirmed use.
    struct Use: Codable, Equatable {
        /// The sentence as it stood when the correction was made, with the term
        /// already written in.
        let said: String
        /// The term inside `said`. Kept because a sentence can hold the word
        /// twice, and the portrait needs to know which one to leave out.
        let span: String
        /// Who put it here. A portrait built from sentences somebody typed by
        /// hand behaves differently from one built out of real dictation, and
        /// telling them apart afterwards is the only way to know which you are
        /// looking at.
        var from: Source = .correction
        /// The other polarity: a sentence where this term does *not* belong.
        ///
        /// Written when a correction runs the other way — the app wrote
        /// `Vercel` and you put `Versailles` back. That says nothing about a
        /// term called Versailles, and everything about where Vercel lives.
        /// `span` is then the word standing at the site, not the term.
        ///
        /// Three of them under one term and `TermPortrait` builds a second
        /// centre from them, and reads a new sentence against both.
        var counter: Bool = false

        enum Source: String, Codable {
            /// The correction panel, the spoken command, or `--learn`.
            case correction
            /// Written by hand with `--learn --in`, to fill a portrait early.
            case seeded
        }

        static func == (a: Use, b: Use) -> Bool { a.said == b.said && a.span == b.span }
    }

    static var url: URL {
        ConfigStore.directory.appendingPathComponent("vocabulary-uses.yaml")
    }

    /// How many uses one term keeps.
    ///
    /// Not a quality limit: with a threshold read off the term's own uses,
    /// more of them separate better rather than worse. This bounds the work of
    /// recomputing a portrait, which is one forward pass per use.
    ///
    /// Each polarity has its own budget. Shared, a term corrected forty times
    /// the wrong way would evict the uses its portrait is built from and leave
    /// it with no portrait at all, and the bound this exists for is the number
    /// of confirmed uses.
    static let keep = 40

    /// The file is there and cannot be parsed as a whole.
    struct Unreadable: LocalizedError {
        var errorDescription: String? {
            "vocabulary-uses.yaml could not be read, so nothing was written over it"
        }
    }

    /// What a reader gets: a file it cannot parse is no uses.
    static func load() -> [String: [Use]] {
        (try? read()) ?? [:]
    }

    /// The same, but a file that is there and does not parse throws.
    ///
    /// A writer has to know the difference. The file is hand-edited, and one
    /// unbalanced quote read as "no uses" would drop every sentence a term had
    /// at the next correction. A row that is gone or malformed is still
    /// forgiven — deleting a row is how the header says to forget a use.
    static func read() throws -> [String: [Use]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        // Present and unreadable is not the same as absent. Bytes that are not
        // UTF-8 have to refuse the write like a syntax error does.
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Unreadable()
        }
        guard let root = try Yams.load(yaml: text) else { return [:] }
        guard let mapping = root as? [String: Any] else { throw Unreadable() }
        let held = mapping["terms"]
        if held == nil || held is NSNull { return [:] }
        guard let terms = held as? [String: Any] else { throw Unreadable() }

        var out: [String: [Use]] = [:]
        for (term, value) in terms {
            guard let rows = value as? [[String: Any]] else { continue }
            let uses = rows.compactMap { row -> Use? in
                guard let said = row["said"] as? String,
                      let span = row["span"] as? String,
                      said.contains(span)
                else { return nil }
                let from = (row["from"] as? String).flatMap(Use.Source.init(rawValue:))
                return Use(
                    said: said, span: span, from: from ?? .correction,
                    counter: row["counter"] as? Bool ?? false
                )
            }
            if !uses.isEmpty { out[term] = uses }
        }
        return out
    }

    /// Adds one use, unless the same sentence is already there.
    ///
    /// The oldest goes when the list is full, so a term that moves on stops
    /// being described by what it used to mean.
    ///
    /// The same sentence and span recorded the other way round replaces what
    /// was there. One sentence cannot both hold the term and refuse it, and
    /// the later correction is the one that stands.
    static func record(
        term: String, said: String, span: String, from: Use.Source = .correction,
        counter: Bool = false
    ) throws {
        let sentence = narrowed(said, to: span)
        // A word, not a substring. `contains` alone let `Vercelli` in.
        guard !sentence.isEmpty, !span.isEmpty,
              occurrence(of: span, in: sentence) != nil else { return }

        var all = try read()
        var uses = all[term] ?? []
        let use = Use(said: sentence, span: span, from: from, counter: counter)
        if let already = uses.firstIndex(of: use) {
            guard uses[already].counter != counter else { return }
            uses.remove(at: already)
        }
        uses.append(use)
        // A budget per polarity, oldest dropped. Sharing one, a term corrected
        // forty times the wrong way evicts every use its portrait is built
        // from, and the term is then left with no portrait at all.
        for polarity in [false, true] {
            let over = uses.filter { $0.counter == polarity }.count - keep
            guard over > 0 else { continue }
            var dropped = 0
            uses.removeAll { use in
                guard dropped < over, use.counter == polarity else { return false }
                dropped += 1
                return true
            }
        }
        all[term] = uses
        try write(all)
    }

    /// Drops every use of one term, and says how many went.
    ///
    /// Case-insensitive, like `--forget` itself: somebody typing `praisy` means
    /// the term.
    @discardableResult
    static func forget(_ term: String) throws -> Int {
        var all = try read()
        let keys = all.keys.filter { $0.caseInsensitiveCompare(term) == .orderedSame }
        let gone = keys.reduce(0) { $0 + (all[$1]?.count ?? 0) }
        guard gone > 0 else { return 0 }
        for key in keys { all[key] = nil }
        try write(all)
        return gone
    }

    /// The one sentence `span` stands in, without the shell prompt in front.
    ///
    /// What is captured is the whole field, and in a terminal that is the whole
    /// prompt line — every dictation glued together since the last Return.
    /// Recorded whole, it taught `Ghostty` that "The night was very ghostly" is
    /// where it lives, in two of its three uses. `RedCrawl`, `Sentry` and
    /// `Tasmeen` each arrived with a single use that was somebody else's text.
    ///
    /// A full stop only ends a sentence when what follows is a space, an
    /// upper-case letter, or nothing. Dictation arrives glued — "terminal.I'm
    /// using" has to come apart — while `Node.js` and `3.5` must not.
    static func narrowed(_ said: String, to span: String) -> String {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = occurrence(of: span, in: text) else { return text }

        func ends(_ i: String.Index) -> Bool {
            guard ".!?".contains(text[i]) else { return false }
            let after = text.index(after: i)
            guard after < text.endIndex else { return true }
            let next = text[after]
            return next.isWhitespace || next.isUppercase
        }

        var from = text.startIndex
        var i = text.startIndex
        while i < at.lowerBound {
            if ends(i) { from = text.index(after: i) }
            i = text.index(after: i)
        }
        var to = text.endIndex
        i = at.upperBound
        while i < text.endIndex {
            if ends(i) { to = text.index(after: i); break }
            i = text.index(after: i)
        }

        var cut = String(text[from ..< to]).trimmingCharacters(in: .whitespaces)
        // The prompt the terminal draws, which is not something anybody said.
        while let first = cut.first, prompts.contains(first) {
            cut = String(cut.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return cut.contains(span) ? cut : text
    }

    /// Where `span` stands as a word, rather than wherever its letters first
    /// appear.
    ///
    /// `range(of:)` matches inside a longer word, so `Vercel` found itself in
    /// `Vercelli` and the sentence about an Italian town was stored as a use of
    /// the hosting platform. Nil means the term does not stand in this text at
    /// all, whatever `contains` says, and nothing should be recorded.
    ///
    /// A term that occurs twice as a word still takes the first: both are
    /// genuine uses, and nothing that records one carries the position of the
    /// occurrence that was corrected.
    static func occurrence(of span: String, in text: String) -> Range<String.Index>? {
        func word(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var from = text.startIndex
        while let found = text.range(of: span, range: from ..< text.endIndex) {
            let before = found.lowerBound == text.startIndex
                || !word(text[text.index(before: found.lowerBound)])
            let after = found.upperBound == text.endIndex || !word(text[found.upperBound])
            if before && after { return found }
            guard found.lowerBound < text.endIndex else { break }
            from = text.index(after: found.lowerBound)
        }
        // Nowhere. `Vercel` in `I visited Vercelli last year.` is not a use of
        // the term, and a caller that only asked `contains` stored it as one.
        return nil
    }

    /// What terminals and shells draw in front of the line being typed.
    static let prompts: Set<Character> = ["❯", ">", "$", "%", "#", "›", "→"]

    /// Rendered by hand rather than by `Yams.dump`, for the same reason
    /// `ConfigWriter` splices `vocabulary.yaml`: this file is meant to be read,
    /// and a dumper reorders and requotes everything it touches.
    static func write(_ all: [String: [Use]]) throws {
        var lines = [
            "# Sentences where a vocabulary term was confirmed, written by the app.",
            "#",
            "# Each one teaches what kind of sentence its term appears in. Delete a line",
            "# that was recorded by mistake; the term forgets it at the next correction.",
            "#",
            "# `counter: true` is the opposite: a sentence where the term does not belong,",
            "# recorded when you put an ordinary word back over it. Its `span` is that word.",
            "",
            "terms:",
        ]
        for term in all.keys.sorted() {
            guard let uses = all[term], !uses.isEmpty else { continue }
            lines.append("  \(quoted(term)):")
            for use in uses {
                lines.append("    - said: \(quoted(use.said))")
                lines.append("      span: \(quoted(use.span))")
                lines.append("      from: \(use.from.rawValue)")
                if use.counter { lines.append("      counter: true") }
            }
        }
        lines.append("")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Double quotes, with everything a double-quoted YAML scalar cannot carry
    /// as itself written as an escape.
    ///
    /// A raw newline is folded back into a space by the parser, which changes
    /// the sentence the portrait is built from. A raw control character —
    /// `\u{7}`, say — makes the whole file unparseable, and then nothing is
    /// ever recorded again.
    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\L"
            case "\u{2029}": out += "\\P"
            default:
                // C0, DEL, and C1 — the last because YAML reads \u{85} as a
                // line break.
                let code = scalar.value
                if code < 0x20 || code == 0x7F || (code >= 0x80 && code <= 0x9F) {
                    out += String(format: "\\x%02X", code)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
