import Foundation

/// `--learn <heard> <corrected>` — adds a replacement rule from the terminal.
///
/// The same code path the correction panel uses, minus the UI. Useful on its
/// own, and it makes the config-rewriting logic testable without a GUI.
///
/// This process never saw the dictation, so it has no clip to name unless one
/// is given with `--clip`. Without it `Corrections.learn` falls back to the most
/// recent dictation whose text contains the rendering, which is the same clip a
/// person typing this at a terminal has in mind.
enum LearnCommand {
    static func run(heard: String, corrected: String, clip: String? = nil) -> Int32 {
        do {
            let outcome = try Corrections.learn(
                heard: heard, corrected: corrected, via: "learn", clip: clip
            )
            // A revert is not a rule learnt, so it does not get the ✓ that says
            // one was. It is the more informative of the two corrections and
            // the line has to say what it actually did.
            if outcome.revert == nil {
                print("✓ \(heard) → \(corrected)")
            } else {
                print("↩ \(heard) → \(corrected) — took the term back, no rule written")
            }
            say(outcome)
            Trace.flush()
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    /// What the audio half did, out loud.
    ///
    /// Every line here is a thing that was written or deleted. A cut that did
    /// not happen and a sample that was capped away are both invisible
    /// otherwise, and a clip nobody knows is missing is the failure this whole
    /// change is trying to avoid.
    static func say(_ outcome: Corrections.Outcome) {
        guard let term = outcome.term else { return }
        if let seen = outcome.seen {
            print("  \(term): seen \(seen) time(s), from correction")
        }
        for line in Corrections.said(about: outcome.revert, term: term) {
            print("  \(line)")
        }
        if let sample = outcome.sample {
            print("  kept the audio as voice/\(sample)")
        } else if let why = outcome.skipped {
            print("  no audio kept — \(why)")
        }
        let bank = outcome.revert == nil ? "samples" : "negatives"
        for gone in outcome.capped {
            print("  capped voice/\(bank)/\(term)/\(gone.file) — \(gone.why)")
        }
        for gone in outcome.pruned {
            print("  dropped \"\(gone)\" — seen once and not again since")
        }
    }
}
