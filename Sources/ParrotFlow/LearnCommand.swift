import Foundation

/// `--learn <heard> <corrected> [kind]` — adds a vocabulary pronunciation from
/// the terminal.
///
/// The same code path the correction panel uses, minus the UI. Useful on its
/// own, and it makes the config-rewriting logic testable without a GUI.
enum LearnCommand {
    static func run(heard: String, corrected: String, kind: WordKind? = nil) -> Int32 {
        do {
            try ConfigWriter.addVocabularyPronunciation(
                term: corrected, heard: heard, kind: kind
            )
            Trace.correction(heard: heard, corrected: corrected, via: "learn")
            print("✓ \(heard) → \(corrected)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }
}
