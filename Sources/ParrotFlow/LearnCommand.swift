import Foundation

/// `--learn <heard> <corrected>` — adds a replacement rule from the terminal.
///
/// The same code path the correction panel uses, minus the UI. Useful on its
/// own, and it makes the config-rewriting logic testable without a GUI.
enum LearnCommand {
    static func run(heard: String, corrected: String) -> Int32 {
        do {
            try ConfigWriter.addReplacement(heard: heard, corrected: corrected)
            Trace.correction(heard: heard, corrected: corrected, via: "learn")
            print("✓ \(heard) → \(corrected)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }
}
