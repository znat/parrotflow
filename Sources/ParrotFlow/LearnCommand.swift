import Foundation

/// `--learn <heard> <corrected> [kind] [--in "<sentence>"]` — adds a vocabulary
/// pronunciation from the terminal.
///
/// The same code path the correction panel uses, minus the UI. Useful on its
/// own, and it makes the config-rewriting logic testable without a GUI.
///
/// `--in` records the sentence as well, which is what a term's portrait is
/// built from. The panel always has one; this command only has one if it is
/// given, so without it the mapping is saved and nothing else.
enum LearnCommand {
    static func run(
        heard: String, corrected: String, kind: WordKind? = nil, sentence: String? = nil
    ) -> Int32 {
        do {
            try ConfigWriter.addVocabularyPronunciation(
                term: corrected, heard: heard, kind: kind
            )
            if let sentence, !sentence.isEmpty {
                try TermUses.record(term: corrected, said: sentence, span: corrected)
            }
            Trace.correction(heard: heard, corrected: corrected, via: "learn")
            print("✓ \(heard) → \(corrected)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }
}
