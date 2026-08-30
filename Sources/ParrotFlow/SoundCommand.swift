import Foundation

/// `--sound` — scores the vocabulary's sound path: `Phonemes` and
/// `VocabularyJudge.phonemeParts`.
///
/// Two things are checked and they fail differently.
///
/// The **similarity** cases pin the Swift metric to the Python that measured
/// the floor. If `Olama`/`Ollama` stops being 1.00 or `praise`/`Praisy` stops
/// being 0.76, the table in `phonemeParts` no longer describes what ships and
/// the floor was chosen for a different function.
///
/// The **proposal** cases are the stage: a sentence goes in, the spans it puts
/// on the judge's menu come out. They cover what the floor is for — `geler`
/// reaches `Gelar`, `praise` does not reach `Praisy` — and the two traps that
/// cost a measurement each: espeak splitting its output on punctuation, and a
/// narrow window claiming a span a wider one should have.
///
/// Skipped, not failed, without espeak-ng. It is not bundled, so CI has none.
enum SoundCommand {

    /// Terms as a vocabulary file would carry them: a term, its renderings,
    /// and the IPA for a rendering whose spelling misleads.
    private static let sounds: [(term: String, form: String, phonemes: String?)] = [
        ("Gelar", "Gelar", nil),
        ("Praisy", "Praisy", nil),
        ("Praisy", "Prissy", nil),
        ("Zylbersztejn", "Zylbersztejn", nil),
        ("Zylbersztejn", "Silverstein", nil),
        ("ParrotFlow", "ParrotFlow", nil),
        ("Ghostty", "Ghostty", nil),
        // espeak reads `Preci` as /pɹɛsaɪ/ — "pre-sigh" — so this rendering
        // reaches nothing until its sound is written down. The pair is what
        // the `phonemes:` key is for.
        ("Praisy", "Preci", "pɹɛsi"),
    ]

    private static let pairs: [(a: String, b: String, want: Float)] = [
        ("Olama", "Ollama", 1.00),
        ("praise", "Praisy", 0.76),
        ("geler", "Gelar", 1.00),
        ("Matthew", "Matthieu", 0.61),
    ]

    /// A sentence, and every span the sound path should offer, as
    /// `word -> term`. Order does not matter; the count does.
    private static let cases: [(name: String, text: String, want: [String])] = [
        ("a word no spelling reaches",
         "I asked geler about the account.", ["geler -> Gelar"]),

        // 0.76, under the floor, and it is a homophone: no number separates
        // these two and the floor is not asked to.
        ("a homophone stays under the floor",
         "Let's praise his work.", []),

        // The line count trap. espeak-ng splits its output on punctuation, so
        // a sentence full of stops used to score every word against some other
        // word's sound — silently, and it reversed a measurement.
        ("punctuation does not shift the answers",
         "Right. Yes! Is geler here? Well, ghosty. Done.",
         ["geler -> Gelar", "ghosty -> Ghostty"]),

        // The rendering generalises. `Silberstein` is 0.90 from the stored
        // `Silverstein` and 0.56 from the term, so only the pair reaches it.
        ("a rendering reaches a spelling nobody wrote down",
         "Silberstein signed it.", ["Silberstein -> Zylbersztejn"]),

        // Written IPA beats the spelling. Without `phonemes:` on `Preci`,
        // espeak sounds it out as "pre-sigh" and this proposes nothing.
        ("a written sound is used instead of the spelling",
         "That is Pressi work.", ["Pressi -> Praisy"]),

        // Widest window first. `parrot flow` is one name, and `flow` alone
        // must not take the span before the pair can.
        // Two words for a term written as one. The sound has no space in it,
        // so the window has to be allowed to be wider than the term is.
        ("a word boundary the decoder invented",
         "I use parrot flow every day.", ["parrot flow -> ParrotFlow"]),

        // Only the model hears this one. espeak reads `Priss y` as
        // /pɹɪswaɪ/ — it sounds out the stranded letter — where the model
        // reads the pair as /pɹɪsi/ and lands on the term. 259 fires in this
        // speaker's archive, and espeak finds none of them.
        ("a word the recogniser split, heard only by the model",
         "I think Priss y wrote that.", ["Priss y -> Praisy"]),

        ("nothing to offer",
         "The meeting is at four.", []),
    ]

    static func run() async -> Int32 {
        let ears = await NeuralPhonemes.isReady()
        guard Phonemes.binary != nil || ears else {
            print("neither ear is available — no espeak-ng and no sound model;"
                + " the sound path is off and this check is skipped")
            return 0
        }
        if !ears {
            print("note: the sound model is not fetched, so only espeak is scored")
        }
        var failures = 0

        // espeak's language-switch note, which is not a sound. English never
        // produces one; French does, and it used to reach the metric.
        let switched = Phonemes.clip("(en)\u{279B}\u{02C8}\u{25CB}(fr) \u{0281}\u{02C8}\u{0254}k")
        let clipped = switched == "\u{279B}\u{25CB}\u{0281}\u{0254}k"
        if !clipped { failures += 1 }
        print("\(clipped ? "✓" : "✗") a language switch is not part of the sound"
            + (clipped ? "" : "  — got \(switched)"))

        for pair in pairs {
            let said = Phonemes.of([pair.a, pair.b], voice: "en-us")
            let score = Phonemes.similarity(said[pair.a] ?? "", said[pair.b] ?? "")
            let ok = abs(score - pair.want) < 0.005
            if !ok { failures += 1 }
            print(String(format: "%@ %@/%@ %.2f%@", ok ? "✓" : "✗", pair.a, pair.b, score,
                         ok ? "" : String(format: "  — wanted %.2f", pair.want)))
        }

        for one in cases {
            let parts = await VocabularyJudge.phonemeParts(
                in: one.text, sounds: sounds, voice: "en-us", language: "en",
                floor: 0.85, claimed: []
            )
            let got = parts.map { "\($0.decoded) -> \($0.other)" }.sorted()
            let ok = got == one.want.sorted()
            if !ok { failures += 1 }
            print("\(ok ? "✓" : "✗") \(one.name)"
                + (ok ? "" : "  — got [\(got.joined(separator: ", "))],"
                    + " wanted [\(one.want.joined(separator: ", "))]"))
        }

        let total = pairs.count + cases.count + 1
        print("\n\(total - failures)/\(total)")
        return failures == 0 ? 0 : 1
    }
}
