import Foundation

/// `--sentence-join` — which periods in this text a pause put there.
///
///     ParrotFlow --sentence-join "You should see a parrot. At the top right."
///       language   en
///       boundary   parrot. At -> parrot at
///       reading    .         -7.2669  5
///       reading    ,         -6.5327  5
///       reading    join      -4.5571  4
///       winner     join
///       text       You should see a parrot at the top right.
///
/// One block per boundary, in order, then the text the stage hands on.
/// `scripts/check-sentence-join.sh` scores the decisions with this. Nothing is
/// downloaded: with no cached model the text comes back untouched and the run
/// says so.
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
            let scan = SentenceJoin.scanned(config.transcription.sentences.marks)
            for boundary in SentenceJoin.boundaries(in: text, scanning: scan) {
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
        guard SentenceReadings.isCached else {
            print("  model      not cached")
            print("  text       \(text)")
            return 0
        }

        var outcome = SentenceJoin.Outcome.unchanged(text)
        let done = DispatchSemaphore(value: 0)
        Task {
            // The app never waits for this load; a run from the shell has to,
            // or every case comes back untouched.
            try? await SentenceReadings.shared.prepare()
            outcome = await SentenceJoin.shared.apply(to: text, config: config)
            done.signal()
        }
        done.wait()

        for reading in outcome.readings {
            print("  boundary   \(reading.change)")
            for score in reading.scores {
                let key = score.key.padding(toLength: 8, withPad: " ", startingAt: 0)
                print(String(format: "  reading    %@ %8.4f  %d",
                             key, score.mean, score.tokens))
            }
            print("  winner     \(reading.winner)")
        }
        print("  text       \(outcome.text)")
        return 0
    }
}
