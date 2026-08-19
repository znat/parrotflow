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

    /// Names first, digits last. Both name passes match on words, and a
    /// mishearing that happens to contain a number word — "Ver Sal two" — has
    /// to still look like words while they run.
    /// Every pass a finished transcript goes through, in the order the
    /// pipeline names — see `Pipeline`.
    ///
    /// Kept as the entry point everything already calls, so moving the order
    /// out of this function did not move the call sites too.
    static func apply(
        to text: String, config: Config, allowPrompts: Bool = true, app: Pipeline.App? = nil,
        seed: Scope = Scope(), findings: Vocabulary.Outcome? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        let (pipeline, language) = Pipeline.forText(text, config: config)
        // The verdict that picked the stages, which until now was computed here
        // and discarded on the same line. Parakeet reports no language of its
        // own, so this is the only one there is to write down.
        Trace.current?.recordLanguage(language)
        var seed = seed
        seed.set("language", .string(language))
        return await pipeline.run(
            text, config: config, allowPrompts: allowPrompts, app: app,
            seed: seed, findings: findings, progress: progress
        )
    }

    // MARK: - Exact

    /// Literal on word boundaries, or a regular expression when the source is
    /// wrapped in slashes. Case-insensitive either way.
    ///
    /// No `{{name}}` expansion. For rules built in code from words a person
    /// typed, never for a table out of the config — those go through `exact`
    /// with `config.expanded`.
    static func applyExact(to text: String, rules: [Config.Transcription.Rule]) -> String {
        exact(to: text, rules: rules).text
    }

    /// The same pass, with how many rules actually fired.
    ///
    /// Split out rather than folded in because the count is only wanted by the
    /// pipeline, which publishes it as `replacements.count` so a later stage can
    /// ask whether this one already did the job. Every other caller wants the
    /// string and nothing else, and `applyExact` above is still exactly what
    /// they were calling.
    ///
    /// Counted per *rule*, not per substitution: "two rules fired" is the
    /// question a condition is asking, and a rule that replaced the same word
    /// four times did one thing, not four.
    /// - Returns: the rewritten text, how many rules fired, what each one wrote
    ///   — `heard -> written`, joined by `; ` — and the substitutions
    ///   themselves. The third is for a stage that has to judge the
    ///   substitutions rather than make them: a judge handed only the finished
    ///   sentence cannot see what changed in it.
    ///
    ///   The fourth is `protected`: the text this pass actually put in, with
    ///   the templates expanded, so `$1.` on "user dot name" reports `user.`
    ///   and not `$1.`. A later stage reads it to leave those characters alone.
    ///   `join` re-cases the first word of a clip and splits a dot it thinks the
    ///   decoder invented, and neither is right on something a table wrote on
    ///   purpose. A `replace:` transform has no code of its own to publish
    ///   from, so this pass publishes on its behalf.
    ///
    /// `expand` turns `{{determiners}}` in a pattern into the list it names,
    /// and returns nil for a name that resolves to nothing. Passed in rather
    /// than reached for, because this type knows about rules and not about the
    /// config they came from.
    static func exact(
        to text: String, rules: [Config.Transcription.Rule],
        expand: (String) -> String? = { $0 }
    ) -> (text: String, count: Int, changes: String, protected: String) {
        var output = text
        var deleted = false
        var fired = 0
        var changes: [String] = []
        var written: [String] = []

        for rule in rules {
            guard let source = expand(rule.pattern) else {
                Log.write("replacements: \"\(rule.source)\" names a word list that is not"
                    + " there; skipped")
                continue
            }
            guard let pattern = try? NSRegularExpression(
                pattern: source, options: [.caseInsensitive]
            ) else {
                Log.write("replacements: \"\(rule.source)\" is not a valid pattern; skipped")
                continue
            }
            let before = output
            // Match by match, back to front, rather than one
            // `stringByReplacingMatches`. Same result, and it is the only way
            // to see what each substitution actually put in: the all-at-once
            // call hands back the finished string and keeps the expansions.
            // Back to front so an earlier replacement cannot move a later match.
            let found = pattern.matches(
                in: output, range: NSRange(output.startIndex..., in: output))
            var wrote: [String] = []
            for match in found.reversed() {
                let expanded = pattern.replacementString(
                    for: match, in: output, offset: 0, template: rule.template)
                guard let range = Range(match.range, in: output) else { continue }
                // What stood there before this rule touched it. A match whose
                // expansion is the text already present wrote nothing, so there
                // is nothing to protect: publishing it would have a later stage
                // treat the speaker's own punctuation as a rule's work.
                let matched = String(output[range])
                output.replaceSubrange(range, with: expanded)
                if !rule.isDeletion, !expanded.isEmpty, expanded != matched {
                    wrote.append(expanded)
                }
            }
            // Back into reading order. The walk is backwards; the list a later
            // stage searches should still run left to right.
            written.append(contentsOf: wrote.reversed())
            if output != before {
                fired += 1
                if rule.isDeletion { deleted = true }
                if !rule.isDeletion { changes.append("\(rule.source) -> \(rule.replacement)") }
            }
        }

        return (
            deleted ? tidy(output) : output, fired,
            changes.joined(separator: "; "),
            // Deduplicated and order-stable: a rule that fired four times wrote
            // one term to protect, not four.
            NSOrderedSet(array: written).array.compactMap { $0 as? String }
                .joined(separator: "; ")
        )
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

    // MARK: - Helpers

    /// Every word in the text, apostrophes included so `Praise's` is one word.
    ///
    /// Not private: `VocabularyJudge.fuzzyParts` walks the same words, and two
    /// definitions of "a word" in one transcript is how a span ends up in one
    /// pass and not the other.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
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
