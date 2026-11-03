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
/// answer — `0` keeps what stands there, `1` takes the other reading, the row
/// past the last reading is "something else", and `-` is a question nobody
/// answered. Several places are several arguments, and they may be given in
/// any order.
///
/// `--taught` prints what each answer teaches instead of the text: the word,
/// and whether a row is written about it. "Something else" is the one answer
/// that writes none.
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

    static func run(
        text: String, places: [String], ranges: Bool = false, taught: Bool = false
    ) -> Int32 {
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
            case "-": answer = nil
            default:
                guard let picked = Int(parts[3]), picked >= 0 else {
                    print("an answer is a row number or -, not \"\(parts[3])\"")
                    return 2
                }
                answer = picked
            }
            // `wrote` says which side the term is on, and nothing here needs
            // to know: the two readings are given by name, and the term is
            // only read when a use is being recorded.
            let place = OpenPlaces.Open(
                was: parts[0], now: parts[1], wrote: false, term: parts[1], word: word
            )
            // A row past "something else" was never offered. Taken as given,
            // `OpenPlaces.written` kept what stands there and called it
            // teaching.
            if let picked = answer, picked > place.elsewhere {
                print("this place offers rows 0 to \(place.elsewhere), not \"\(parts[3])\"")
                return 2
            }
            open.append(place)
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
            located, answers: taken, in: text, refusing: { _, word in word }
        )
        // The word and where it ended up, which is what the trace records. A
        // place after one the answer made longer or shorter has moved, and
        // nothing else prints that.
        guard !taught else {
            print(done.words.prefix(taken.count)
                .map { "\($0.word) \($0.teaches ? "teaches" : "nothing")" }
                .joined(separator: "; "))
            return 0
        }
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
