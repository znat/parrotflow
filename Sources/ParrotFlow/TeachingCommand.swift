import Foundation

/// Whether a substitution sits inside a spelling lesson.
///
///     ParrotFlow --teaching "Hey Barrot Versal Spells V E R C E L" Versal
///     REVERT
///     ParrotFlow --teaching "upload and Versal. Sending the file" Versal
///     ASK
///
/// `VocabularyJudge.teaching` decides this with no model, no audio and no
/// config behind it, and what it decides is whether a name is written over the
/// word a correction is teaching. This is the entry point
/// `scripts/check-spells-rule.sh` scores, so the set runs against the shipped
/// function rather than against a copy of it.
enum TeachingCommand {
    static func run(text: String, word: String) -> Int32 {
        guard let range = text.range(of: word) else {
            print("not found: \(word)")
            return 2
        }
        let change = VocabularyJudge.Change(
            range: range, was: word, now: word, terms: [], standing: .rule
        )
        let taught = VocabularyJudge.teaching(in: text, changes: [change])
        print(taught[0] ? "REVERT" : "ASK")
        return 0
    }
}
