import Foundation

/// Where an open place lands in the text that shipped, and what an answer
/// writes there.
///
///     ParrotFlow --selector "can you ask Mick to review it." \
///       "Mick|mixed bend|3|1"
///     can you ask mixed bend to review it.
///
/// A place is `standing|other|word|answer`: what stands in the text, the
/// reading nobody took, where the stage saw it counted in words, and the
/// answer — `0` keeps what stands there, `1` takes the other reading, and `-`
/// is a question nobody answered. Several places are several arguments, and
/// they may be given in any order.
///
/// This is the half of the pill that is not drawing: `OpenPlaces.located`
/// finds the span again in a text later stages may have rewritten, and
/// `OpenPlaces.written` puts the answers back without touching anything
/// between them. `scripts/check-selector.sh` scores this entry point, so the
/// set runs against the shipped functions rather than a copy of them.
///
/// `--ranges` prints where each answered word ended up instead of the text,
/// which is what `Trace.chose` records: a place after one the answer made
/// longer or shorter has moved, and nothing else shows that.
///
/// The refusal is written plainly here — `other` as given. The app also asks
/// `VocabularyPass.lowercased` about a glued span, which needs a tagger and
/// the vocabulary; `--lowercase-refused` is where that half is scored.
enum SelectorCommand {

    static func run(text: String, places: [String], ranges: Bool = false) -> Int32 {
        var open: [OpenPlaces.Open] = []
        var answers: [Int?] = []
        for argument in places {
            let parts = argument.split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 4, let word = Int(parts[2]) else {
                print("a place is standing|other|word|answer, not \"\(argument)\"")
                return 2
            }
            let answer: Int?
            switch parts[3] {
            case "0": answer = 0
            case "1": answer = 1
            case "-": answer = nil
            default:
                print("an answer is 0, 1 or -, not \"\(parts[3])\"")
                return 2
            }
            // `wrote` says which side the term is on, and nothing here needs
            // to know: the two readings are given by name, and the term is
            // only read when a use is being recorded.
            open.append(OpenPlaces.Open(
                was: parts[0], now: parts[1], wrote: false, term: parts[1], word: word
            ))
            answers.append(answer)
        }
        let located = OpenPlaces.located(open, in: text)
        guard !located.isEmpty else {
            print("NOTHING FOUND")
            return 0
        }
        // Back in the order the places were located in, which is left to
        // right and not the order they were typed.
        let ordered = located.map { place -> Int? in
            guard let at = open.firstIndex(where: { $0 == place.open }) else { return nil }
            return answers[at]
        }
        // A run stops at the first place nobody answered: the questions are
        // asked one at a time, so nothing after an unanswered one was asked
        // either.
        let taken = ordered.prefix { $0 != nil }.compactMap { $0 }
        let done = OpenPlaces.written(
            located, answers: taken, in: text, refusing: { $0.open.other }
        )
        // The word and where it ended up, which is what the trace records. A
        // place after one the answer made longer or shorter has moved, and
        // nothing else prints that.
        guard !ranges else {
            // The answered ones only. `written` returns a row per located
            // place, and the rows past the last answer are what stands there
            // rather than anything anybody picked.
            print(done.words.prefix(taken.count)
                .map { "\($0.word)@\($0.range.lowerBound)-\($0.range.upperBound)" }
                .joined(separator: " "))
            return 0
        }
        print(done.text)
        return 0
    }
}
