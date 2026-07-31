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
    static func run(text: String?) -> Int32 {
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
            let out = Numbers.apply(to: sample)
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
}
