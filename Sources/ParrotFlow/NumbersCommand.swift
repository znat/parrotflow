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
    /// `--lang` carries a list, not a language: one entry pins that grammar,
    /// several stand in for the configured list so detection and its fallback
    /// run exactly as the app would. Without it a case file silently describes
    /// whichever languages the machine happens to have configured — which is
    /// how this set scored 91/97 on a config listing only English, for a reason
    /// that had nothing to do with the numbers.
    static func run(text: String?, quiet: Bool = false, languages: [String]? = nil) -> Int32 {
        func convert(_ input: String) -> String {
            guard let languages, !languages.isEmpty else {
                return Numbers.apply(to: input, languages: configuredLanguages())
            }
            return languages.count == 1
                ? Numbers.apply(to: input, language: languages[0])
                : Numbers.apply(to: input, languages: languages)
        }

        // `--quiet` prints the rewritten line and nothing else, which is what
        // scripts/check-numbers.sh reads. `--lang` pins the grammar instead of
        // detecting it, so a two-word case can be scored without being a
        // sentence long enough for the language recogniser.
        if quiet, let text {
            print(convert(text))
            return 0
        }

        // Whether dictation actually gets this is now a question about the
        // pipeline, and the answer differs per language — so say which.
        if let config = try? ConfigStore.load() {
            let carrying = config.transcription.languages.filter { language in
                Pipeline.resolved(config: config, language: language).stages.contains(.numbers)
            }
            if carrying.isEmpty {
                print("no pipeline runs numbers — dictation is unaffected by what follows")
            } else {
                print("pipeline: numbers runs for \(carrying.joined(separator: ", "))")
            }
        } else {
            print("the config could not be read; what follows is the pass on its own")
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
            let out = convert(sample)
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
