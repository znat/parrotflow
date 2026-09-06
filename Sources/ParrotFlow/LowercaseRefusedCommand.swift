import Foundation

/// How a glued span the sentence refused is written back.
///
///     ParrotFlow --lowercase-refused "Better Stack" \
///       "a much Better Stack than before"
///     better stack
///     ParrotFlow --lowercase-refused "Mont Blanc" "We climbed Mont Blanc."
///     AS HEARD
///
/// `VocabularyJudge.lowercased` decides this with no model and no audio behind
/// it. This is the entry point `scripts/check-lowercase-refused.sh` scores, so
/// the set runs against the shipped function rather than against a copy of it.
///
/// The span is located by its first occurrence in the text, which is what
/// gives the tagger the offset it needs.
enum LowercaseRefusedCommand {
    static func run(span: String, text: String, terms: [String]) -> Int32 {
        guard let range = text.range(of: span) else {
            print("not found: \(span)")
            return 2
        }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        guard let written = VocabularyJudge.lowercased(
            span, in: text, at: offset, terms: terms
        ) else {
            print("AS HEARD")
            return 0
        }
        print(written)
        return 0
    }
}
