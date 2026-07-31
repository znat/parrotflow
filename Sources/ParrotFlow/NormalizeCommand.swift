import FluidAudio
import Foundation

/// `--normalize "<text>"` — runs FluidAudio's inverse text normalisation and
/// reports whether the native library is actually linked.
///
/// Worth having as a check rather than an assumption: `normalize` returns its
/// input unchanged when the library is missing, so a silent no-op is
/// indistinguishable from a rule that did not match.
enum NormalizeCommand {
    static func run(text: String?) -> Int32 {
        let normalizer = TextNormalizer.shared
        print("native library: \(normalizer.isNativeAvailable ? "linked" : "NOT LINKED — normalize() is a no-op")")
        if let version = normalizer.version { print("version:        \(version)") }
        print("custom rules:   \(normalizer.ruleCount)")
        print("")

        let samples = text.map { [$0] } ?? [
            "two hundred",
            "five dollars and fifty cents",
            "january fifth twenty twenty five",
            "the fifth of january twenty twenty five",
            "two thirty pm",
            "nineteen eighty four",
            "twenty five percent",
            "version three point two",
            "call me at five five five one two three four",
            "it costs about fifteen euros",
        ]
        for sample in samples {
            let out = normalizer.normalize(sample)
            let mark = out == sample ? "·" : "→"
            print("  \(mark) \(sample)")
            if out != sample { print("      \(out)") }
        }
        return 0
    }
}
