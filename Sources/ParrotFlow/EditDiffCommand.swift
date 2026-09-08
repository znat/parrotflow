import Foundation

/// `--edit-diff "<before>" "<now>"` — the one span that changed, or nothing.
///
///     ParrotFlow --edit-diff "the Vercel Castle is closed" "the Versailles Castle is closed"
///     Vercel -> Versailles
///
/// `EditWatch.changes` decides whether a field that no longer says what was
/// dictated holds a correction or a rewrite, and a rewrite read as a correction
/// teaches a term the wrong sentence. `EditWatch.refusal` then decides whether
/// the correction is about a name. Neither has accessibility or timing behind
/// it, so both have a set.
enum EditDiffCommand {
    static func run(before: String, now: String, language: String) async -> Int32 {
        let changes = EditWatch.changes(from: before, to: now)
        guard !changes.isEmpty else {
            print("no single change")
            return 0
        }
        for change in changes {
            print("\(change.was) -> \(change.now)")
            // Whether a capital here means anything. `teaches` offers a
            // correction onto a capitalised word unless the word opens a
            // sentence, where every word is capitalised and the capital says
            // nothing about the word.
            print("  opens: \(EditWatch.opensSentence(in: change.sentence, at: change.nowAt))")
            // Zero means neither ear answered: no espeak-ng, no model.
            let sound = await EditWatch.soundsAlike(
                change.was, change.now, language: language
            )
            print("  sound: \(String(format: "%.2f", sound))")
            // Whether the panel would offer it. The two word lists are the
            // real ones, so the answer is this machine's — and it is the same
            // call the app makes, so this cannot print a decision it would not.
            // The word lists on their own, before age or sound or the cut
            // guard. `score-offers.py` scores the baseline off this line: read
            // off `offer:` instead, it moves whenever a later rule moves.
            print("  words: \(EditWatch.refusal(for: change) == nil ? "yes" : "no")")
            // `offers` alone decides. `refusal` only picks the wording of a
            // yes, so `score-offers.py` can still tell the two ways in apart.
            switch (EditWatch.offers(change, sound: sound), EditWatch.refusal(for: change)) {
            case (.some(let refusal), _):
                print("  offer: no, \(refusal)")
            case (.none, .none):
                print("  offer: yes")
            case (.none, .some):
                print("  offer: yes, ordinary English but it sounds like it")
            }
            // What `trace.jsonl` would keep: the window as heard and where
            // the heard word stands in it.
            let heard = EditWatch.asHeard(change)
            print("  heard: \(heard.range.lowerBound)..<\(heard.range.upperBound) in \"\(heard.text)\"")
            // What the pill would ask. A wrong split is invisible there.
            let payload = AppDelegate.learnPayload(for: change)
            print("  learn: \(payload.line)")
            // The geometry, because the fault this window fixes was visual and
            // nothing could see it from here. Two rows means the row measured
            // for one is being asked to draw two.
            let rows = Int(PillMetrics.learnRows(payload) / PillMetrics.learnRow)
            print("  pill: \(Int(PillMetrics.learnWidth(payload)))px wide,"
                + " \(rows) row(s)")
        }
        print("  in: \(changes[0].sentence)")
        return 0
    }
}
