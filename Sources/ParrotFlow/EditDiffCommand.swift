import Foundation

/// `--edit-diff "<before>" "<now>"` — the one span that changed, or nothing.
///
///     ParrotFlow --edit-diff "the Vercel Castle is closed" "the Versailles Castle is closed"
///     Vercel -> Versailles
///
/// `EditWatch.change` decides whether a field that no longer says what was
/// dictated holds a correction or a rewrite, and a rewrite read as a correction
/// teaches a term the wrong sentence. It is a pure function with no
/// accessibility and no timing behind it, so it has a set.
enum EditDiffCommand {
    static func run(before: String, now: String) -> Int32 {
        guard let change = EditWatch.change(from: before, to: now) else {
            print("no single change")
            return 0
        }
        print("\(change.was) -> \(change.now)")
        print("  in: \(change.sentence)")
        return 0
    }
}
