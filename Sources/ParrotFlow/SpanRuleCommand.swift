import Foundation

/// `--span-rule` — scores `Surface.writableSpan` on before/after pairs.
///
/// The other half of `scripts/check-span.sh`. That one starts from a range that
/// is already known and asks whether a real app writes exactly those characters.
/// This asks the question before it: given a sentence and its rewrite, which
/// range should be handed over at all.
///
/// Pure, so it needs no app, no window and no accessibility. It is also where
/// the answer was wrong three times in one afternoon, each time in a way that
/// only showed up as a rewrite quietly not happening.
enum SpanRuleCommand {

    /// `before`, `after`, and the whole of what should be written: the
    /// characters the span covers, and what they become.
    private static let cases: [(name: String, before: String, after: String,
                                covers: String, becomes: String)] = [
        // 2026-08-20, Slack. The minimal answer is nothing-becomes-"do ", and
        // Slack drops the trailing space off the paste: "one doyou".
        ("a word inserted between two words",
         "In the categories above, which one you recommend?",
         "In the categories above, which one do you recommend?",
         "y", "do y"),

        // 2026-08-20, Slack. Minimally nothing-becomes-",", which asks to paste
        // at a caret — and an empty selection confirms itself wherever the caret
        // is, so there is nothing for step 2 of the ladder to check.
        ("a comma inserted mid-sentence",
         "I don't know whether the dictation will be clearly understood in a car though.",
         "I don't know whether the dictation will be clearly understood in a car, though.",
         " t", ", t"),

        // 2026-08-20, Slack. Minimally "'ll t I"-becomes-nothing, and
        // `TextInserter.insert("")` returns without writing anything, so the
        // ladder cannot tell this from an app that refused the edit.
        ("a stutter deleted from the front",
         "I'll t I told you I will tell you when my dictation app is ready to test.",
         "I told you I will tell you when my dictation app is ready to test.",
         "I'll t I t", "I t"),

        // A letter added inside a word. Minimally nothing-becomes-"r", and one
        // character either side is all it takes to make that writable.
        ("a letter added inside a word",
         "PFCHK Jery is on vacation", "PFCHK Jerry is on vacation",
         "y", "ry"),

        // A whole sentence rewritten. Nothing to grow.
        ("the ends differ",
         "sixty euros", "60 EUR",
         "sixty euros", "60 EUR"),

        // Growth runs off the end of the line and has to turn round.
        ("the edit is at the very end",
         "ask him on Monday", "ask him on Monday.",
         "y", "y."),
    ]

    static func run() -> Int32 {
        var failures = 0
        for one in cases {
            guard let (range, replacement) = Surface.writableSpan(
                from: one.before, to: one.after
            ) else {
                print("✗ \(one.name)  — no span at all")
                failures += 1
                continue
            }
            let covers = String(one.before[range])
            let rebuilt = one.before.replacingCharacters(in: range, with: replacement)

            var wrong: [String] = []
            if covers != one.covers || replacement != one.becomes {
                wrong.append("\"\(covers)\" → \"\(replacement)\","
                    + " wanted \"\(one.covers)\" → \"\(one.becomes)\"")
            }
            // The rules the span has to satisfy, checked rather than assumed:
            // the expectations above are one reading of them and could be
            // written down wrong.
            if rebuilt != one.after { wrong.append("rebuilds as \"\(rebuilt)\"") }
            if range.isEmpty { wrong.append("covers no characters") }
            if replacement.isEmpty { wrong.append("nothing to paste") }
            if replacement.first?.isWhitespace == true { wrong.append("starts on whitespace") }
            if replacement.last?.isWhitespace == true { wrong.append("ends on whitespace") }

            print("\(wrong.isEmpty ? "✓" : "✗") \(one.name)"
                + (wrong.isEmpty ? "" : "  — \(wrong.joined(separator: "; "))"))
            if !wrong.isEmpty { failures += 1 }
        }

        print(failures == 0
            ? "\n\(cases.count)/\(cases.count)"
            : "\n\(cases.count - failures)/\(cases.count)")
        return failures == 0 ? 0 : 1
    }
}
