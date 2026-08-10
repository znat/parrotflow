import Foundation

/// What the judge reads out of a model's reply.
///
///     ParrotFlow --verdicts 2 "1. KEEP
///     2. REVERT"                                  # -> KEEP REVERT
///
/// `VocabularyJudge.verdicts` is a pure function with no model, no audio and
/// no config behind it, and it decides which substitutions survive a
/// dictation. A reply this reads wrongly is a name written into somebody's
/// sentence, so it has a set. This is the entry point
/// `scripts/check-verdicts.sh` scores, so the set runs against the shipped
/// function rather than against a copy of it.
enum VerdictsCommand {
    static func run(count: Int, reply: String) -> Int32 {
        guard count > 0 else {
            print("usage: ParrotFlow --verdicts <count> <reply>")
            return 2
        }
        print(VocabularyJudge.verdicts(reply, count: count)
            .map { $0 ? "KEEP" : "REVERT" }
            .joined(separator: " "))
        return 0
    }
}
