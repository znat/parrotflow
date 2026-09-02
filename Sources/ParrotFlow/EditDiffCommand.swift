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
    static func run(before: String, now: String) -> Int32 {
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
            // Whether the panel would offer it. The two word lists are the
            // real ones, so the answer is this machine's.
            if let refusal = EditWatch.refusal(for: change) {
                print("  offer: no, \(refusal)")
            } else {
                print("  offer: yes")
            }
        }
        print("  in: \(changes[0].sentence)")
        return 0
    }
}
