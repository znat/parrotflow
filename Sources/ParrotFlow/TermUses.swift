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
                return Use(said: said, span: span, from: from ?? .correction)
            }
            if !uses.isEmpty { out[term] = uses }
        }
        return out
    }

    /// Adds one use, unless the same sentence is already there.
    ///
    /// The oldest goes when the list is full, so a term that moves on stops
    /// being described by what it used to mean.
    static func record(
        term: String, said: String, span: String, from: Use.Source = .correction
    ) throws {
        let sentence = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, !span.isEmpty, sentence.contains(span) else { return }

        var all = try read()
        var uses = all[term] ?? []
        let use = Use(said: sentence, span: span, from: from)
        guard !uses.contains(use) else { return }
        uses.append(use)
        if uses.count > keep { uses.removeFirst(uses.count - keep) }
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

    /// Rendered by hand rather than by `Yams.dump`, for the same reason
    /// `ConfigWriter` splices `vocabulary.yaml`: this file is meant to be read,
    /// and a dumper reorders and requotes everything it touches.
    static func write(_ all: [String: [Use]]) throws {
        var lines = [
            "# Sentences where a vocabulary term was confirmed, written by the app.",
            "#",
            "# Each one teaches what kind of sentence its term appears in. Delete a line",
            "# that was recorded by mistake; the term forgets it at the next correction.",
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
