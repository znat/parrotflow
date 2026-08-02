import AppKit
import Foundation

/// Rewrites misheard names in a finished transcript.
///
/// Two passes. The exact one substitutes spellings you have taught. The fuzzy
/// one catches renderings you have not: a name arrives a different way almost
/// every time — `Supabase` has turned up as "Super Base", "super bays",
/// "superbase" and "superbees" — and an exact map needs a new entry for each.
///
/// Fuzzy matching is only safe because of one asymmetry: **misheard names are
/// not words**. "Versel" is not in any dictionary; "Excel" is. Checking each
/// candidate against the spell checker is what keeps `Excel => Vercel` and
/// `Matthew => Matthieu` from happening, and it is the guard that acoustic
/// boosting had no equivalent of.
enum Replacements {

    /// Word-similarity floor. Measured over 2168 words of real transcripts:
    /// at 0.75 two-word windows over-reach ("Tasmi and" => Tasmeen), at 0.80
    /// nineteen names are caught with nothing wrongly replaced.
    static let threshold = 0.80

    /// Longest window considered. Recognition splits names it does not know,
    /// so "Ver Sal" has to reach "Vercel". Three-word windows were measured
    /// and caught nothing extra.
    static let maximumWindow = 2

    /// Below this, similarity stops discriminating.
    static let minimumLength = 5

    /// Names first, digits last. Both name passes match on words, and a
    /// mishearing that happens to contain a number word — "Ver Sal two" — has
    /// to still look like words while they run.
    /// Every pass a finished transcript goes through, in the order the
    /// pipeline names — see `Pipeline`.
    ///
    /// Kept as the entry point everything already calls, so moving the order
    /// out of this function did not move the call sites too.
    static func apply(
        to text: String, config: Config, allowPrompts: Bool = true, app: Pipeline.App? = nil
    ) async -> String {
        await Pipeline.forText(text, config: config).0.run(
            text, config: config, allowPrompts: allowPrompts, app: app
        )
    }

    // MARK: - Exact

    /// Literal on word boundaries, or a regular expression when the source is
    /// wrapped in slashes. Case-insensitive either way.
    static func applyExact(to text: String, rules: [Config.Transcription.Rule]) -> String {
        var output = text
        var deleted = false

        for rule in rules {
            guard let pattern = try? NSRegularExpression(
                pattern: rule.pattern, options: [.caseInsensitive]
            ) else {
                Log.write("replacements: \"\(rule.source)\" is not a valid pattern; skipped")
                continue
            }
            let before = output
            output = pattern.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: rule.template
            )
            if rule.isDeletion, output != before { deleted = true }
        }

        return deleted ? tidy(output) : output
    }

    /// Closes the gaps a deletion leaves — doubled spaces, a space before a
    /// comma, a lowercase word left at the start of a sentence.
    static func tidy(_ text: String) -> String {
        var output = text
        for (pattern, template) in [
            ("[ \\t]{2,}", " "),          // "So  I was" after a filler went
            (" +([,.;:!?])", "$1"),      // "thinking ," 
            ("([,;:]) *([,.;:])", "$2"), // "was, , thinking"
            ("^[ \\t]+", ""),
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            output = regex.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output),
                withTemplate: template
            )
        }
        output = output.trimmingCharacters(in: .whitespaces)
        // A removed leading filler leaves the sentence starting lowercase.
        if let first = output.first, first.isLowercase {
            output = first.uppercased() + output.dropFirst()
        }
        return output
    }

    // MARK: - Fuzzy

    static func applyFuzzy(to text: String, targets: [String]) -> String {
        let usable = targets.filter { $0.count >= minimumLength }
        guard !usable.isEmpty else { return text }

        let words = wordRanges(in: text)
        guard !words.isEmpty else { return text }

        // Score every window, then take the best non-overlapping ones. Taking
        // the first match above threshold instead let a two-word window win
        // over the one-word window inside it — "on Superbase" scored enough to
        // beat nothing, and swallowed the "on".
        struct Candidate {
            let indices: [Int]
            let range: Range<String.Index>
            let target: String
            let score: Double
        }
        var candidates: [Candidate] = []

        for size in 1...maximumWindow where words.count >= size {
            for start in 0...(words.count - size) {
                let indices = Array(start..<(start + size))
                let span = words[indices.first!].lowerBound..<words[indices.last!].upperBound
                let phrase = String(text[span])
                let joined = phrase.filter { !$0.isWhitespace }
                guard joined.count >= minimumLength, !isRealWord(joined) else { continue }
                if size == 1, isRealWord(phrase) { continue }

                // A window holding a correct spelling already is left alone.
                // The exact pass runs first, so by now "Superbase" is already
                // "Supabase" — and "on Supabase" still scores above threshold
                // against "Supabase", which swallowed the preceding word.
                let tokens = indices.map { String(text[words[$0]]).lowercased() }
                if tokens.contains(where: { token in
                    usable.contains { $0.lowercased() == token }
                }) { continue }

                guard let best = usable
                    .map({ ($0, similarity(phrase, $0)) })
                    .max(by: { $0.1 < $1.1 }),
                    best.1 >= threshold
                else { continue }

                candidates.append(Candidate(indices: indices, range: span, target: best.0, score: best.1))
            }
        }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var consumed = Set<Int>()
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard candidate.indices.allSatisfy({ !consumed.contains($0) }) else { continue }
            replacements.append((candidate.range, candidate.target))
            candidate.indices.forEach { consumed.insert($0) }
        }

        guard !replacements.isEmpty else { return text }

        var output = text
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            Log.write("fuzzy: \"\(text[replacement.range])\" → \(replacement.text)")
            output.replaceSubrange(replacement.range, with: replacement.text)
        }
        return output
    }

    // MARK: - Helpers

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        guard let pattern = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}']+") else { return [] }
        return pattern
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }

    /// Whether the spell checker recognises it, in either language we support.
    ///
    /// Checked lowercased: the checker waves through anything that looks like
    /// CamelCase, so "VerSal" came back as a known word while "versal" did not,
    /// and a name split by the recogniser was filtered out for the wrong reason.
    ///
    /// Cached because a transcript produces one query per candidate window.
    ///
    /// The service behind it is not always there. `NSSpellServer
    /// findMisspelledWordInString timed out` has been seen four calls in a row
    /// on a warm machine, and there is no way to tell a timeout from an answer:
    /// `checkSpelling` returns a range, and a failed lookup returns the same
    /// `NSNotFound` a known word does. So a timeout reads as "this is a real
    /// word", fuzzy declines to touch it, and a name that should have been
    /// corrected is not.
    ///
    /// That is the safe direction — a missed correction rather than an invented
    /// one — and it is why tests/replacement-cases.txt has twice come back
    /// 19/20 and then refused to reproduce. Worth knowing before treating an
    /// odd fuzzy result as a scoring bug: this pass is not deterministic, and
    /// no amount of threshold tuning makes it so.
    private static var wordCache: [String: Bool] = [:]
    private static let cacheLock = NSLock()

    static func isRealWord(_ word: String) -> Bool {
        let key = word.lowercased()
        cacheLock.lock()
        if let cached = wordCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        var known = false
        for language in ["en", "fr"] {
            let range = NSSpellChecker.shared.checkSpelling(
                of: key, startingAt: 0, language: language,
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            )
            if range.location == NSNotFound { known = true; break }
        }

        cacheLock.lock()
        wordCache[key] = known
        cacheLock.unlock()
        return known
    }

    /// Edit distance discounting letters recognition confuses, normalised and
    /// insensitive to spacing — so "Ver Sal" scores against "Vercel" exactly as
    /// "Versal" does.
    static func similarity(_ a: String, _ b: String) -> Double {
        VoiceCommand.similarity(a, b)
    }
}
