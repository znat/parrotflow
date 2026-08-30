import Foundation

/// `--sentence-join` — which periods in this text a pause put there.
///
///     ParrotFlow --sentence-join "You should see a parrot. At the top right."
///       language   en
///       boundary   parrot. At -> parrot at
///       score      -5.07
///       tier       join
///       text       You should see a parrot at the top right.
///
/// One `boundary`/`score`/`tier` block per boundary, in order, then the text
/// the stage hands on. `scripts/check-sentence-join.sh` scores the two tiers
/// with this. Nothing is downloaded: with no cached model the text comes back
/// untouched and the run says so, which is what the app does.
///
/// `--case` asks the lowercasing question alone and loads no model, so it runs
/// on a machine that has never dictated. `scripts/check-sentence-case.sh` is
/// the run.
///
///     ParrotFlow --sentence-join --case "I will ask him. Nathan knows."
///       next       Nathan -> Nathan
@available(macOS 14, *)
enum SentenceJoinCommand {

    static func run(_ text: String, caseOnly: Bool) -> Int32 {
        let config = (try? ConfigStore.load()) ?? Config()
        if caseOnly {
            let terms = Array(config.vocabulary.terms.keys)
            for boundary in SentenceJoin.boundaries(in: text) {
                let (whole, offset) = SentenceJoin.joining(text, at: boundary)
                let word = String(text[boundary.next])
                let now = SentenceJoin.written(word, in: whole, at: offset, terms: terms)
                print("  next       \(word) -> \(now)")
            }
            return 0
        }

        let language = Pipeline.language(of: text, config: config)
        print("  language   \(language)")
        guard language == "en" else {
            print("  text       \(text)")
            return 0
        }
        guard SentenceModel.isCached else {
            print("  probe      not cached")
            print("  text       \(text)")
            return 0
        }

        var outcome = SentenceJoin.Outcome.unchanged(text)
        let done = DispatchSemaphore(value: 0)
        Task {
            outcome = await SentenceJoin.shared.apply(to: text, config: config)
            done.signal()
        }
        done.wait()

        for reading in outcome.readings {
            print("  boundary   \(reading.change)")
            print(String(format: "  score      %.4f", reading.score))
            print("  tier       \(reading.tier.rawValue)")
        }
        print("  text       \(outcome.text)")
        return 0
    }
}
