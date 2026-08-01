import Foundation

/// `--numbers "<text>"` — runs the spoken-number pass over a line and prints
/// the result. With no argument it runs the samples below, which are the cases
/// the rules were written against: one per rule, and one per guard that keeps
/// the rule off ordinary English.
///
/// The pass always runs here, whatever the config says — the point is to see
/// what it does before deciding. Whether dictation gets it is printed first, so
/// the two are not confused.
enum NumbersCommand {
    static func run(text: String?, quiet: Bool = false, language: String? = nil) -> Int32 {
        // `--quiet` prints the rewritten line and nothing else, which is what
        // scripts/check-numbers.sh reads. `--lang` pins the grammar instead of
        // detecting it, so a two-word case can be scored without being a
        // sentence long enough for the language recogniser.
        if quiet, let text {
            print(language.map { Numbers.apply(to: text, language: $0) }
                ?? Numbers.apply(to: text, languages: configuredLanguages()))
            return 0
        }

        let enabled = (try? ConfigStore.load())?.transcription.numbers
        switch enabled {
        case true?: print("transcription.numbers: on — dictation gets this")
        case false?: print("transcription.numbers: off — dictation is unaffected by what follows")
        case nil: print("transcription.numbers: unknown — the config could not be read")
        }
        print("")

        let samples = text.map { [$0] } ?? [
            // Cardinals, and the threshold that leaves small ones alone
            "two hundred forty-three.",
            "two hundred and forty-three",
            "twenty-five people",
            "about twelve of them",
            "I have one question",
            "no one knows",
            "chapter three",
            "a hundred and fifty bucks",
            "two hundred fifty thousand",
            // Extras
            "three point one four",
            "the twenty third of June",
            "the fifth of January",
            "nineteen eighty-four",
            "it shipped in twenty twenty five",
            "call five five five one two three four",
            // Guards
            "let's meet at eleven thirty",
            "two three-inch bolts",
            "a thirty second timeout",
            "one and two came back",
        ]

        var changed = 0
        for sample in samples {
            let out = language.map { Numbers.apply(to: sample, language: $0) }
                ?? Numbers.apply(to: sample, languages: configuredLanguages())
            if out == sample {
                print("  · \(sample)")
            } else {
                changed += 1
                print("  → \(sample)")
                print("      \(out)")
            }
        }
        print("")
        print("\(changed) of \(samples.count) rewritten")
        return 0
    }

    /// The languages the app would try, so this command and the dictation path
    /// answer the same question the same way. `--lang` overrides it to score
    /// one grammar on its own.
    private static func configuredLanguages() -> [String] {
        (try? ConfigStore.load())?.transcription.languages ?? ["en"]
    }
}
