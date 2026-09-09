import Foundation

/// The places one dictation's vocabulary pass could not settle, kept until the
/// pill can ask about them.
///
/// The stage decides and the pill asks, and there is a decoder, a pipeline and
/// two thread hops between them. `Transcriber.transcribe` returns a string, so
/// the places cannot come back the way the text does — the same problem
/// `InputBox` has with the field it read at the press, and the same answer: a
/// dictionary keyed by press run, written by whoever is on the pipeline's
/// thread and read on the main one.
///
/// Keyed by press run and not by "the last dictation", because push-to-talk
/// does not wait: a second press can be recording while this one's places are
/// still on their way.
enum OpenPlaces {

    /// One place the free gates left open, and the two readings of it.
    ///
    /// Both readings, and which of them is in the string. That last part is
    /// not a detail: a `replacements` rule has already written its term into
    /// the transcript, so what stands there is `now`, and a sound proposal
    /// writes nothing, so what stands there is `was`. The pill's first option
    /// is always what is already written — answering it changes nothing — and
    /// which side the term is on flips with the source.
    struct Open: Equatable {
        /// What the decoder wrote over this span.
        let was: String
        /// The term as it would be written there, inflected as the span needs.
        let now: String
        /// Whether the stage left `now` in the string. False means `was`.
        let wrote: Bool
        /// The vocabulary term this place is about, for the uses it teaches.
        let term: String
        /// Where the span sits in the stage's text, counted in words.
        ///
        /// The stages after `vocabulary` may rewrite, so the span is searched
        /// for again in the text that actually landed. A sentence naming the
        /// same word twice gives two hits, and this is how the right one is
        /// picked.
        let word: Int

        /// What is written there now, which is the pill's option 0.
        var standing: String { wrote ? now : was }
        /// The reading nobody has taken, which is the pill's option 1.
        var other: String { wrote ? was : now }
    }

    /// One place, and where it turned out to be in the text that landed.
    struct Placed: Equatable {
        let range: Range<String.Index>
        let open: Open
    }

    /// Where each place sits in the words that actually landed.
    ///
    /// The stages after `vocabulary` may rewrite, so a span is searched for
    /// again rather than trusted — and a span that is gone is a question
    /// nobody can answer, so it is dropped. A word, not a substring: the same
    /// test the uses file makes, so `Vercel` does not find itself in
    /// `Vercelli`.
    ///
    /// A sentence naming the word twice gives two hits, and the place's own
    /// word index is the only thing that tells them apart. Two places never
    /// take the same hit.
    ///
    /// Returned left to right, which is the order the questions are asked in
    /// and the order the write walks.
    static func located(_ places: [Open], in text: String) -> [Placed] {
        var found: [Placed] = []
        var taken: [Range<String.Index>] = []
        func words(before at: String.Index) -> Int {
            text[..<at].split(separator: " ").count
        }
        for place in places {
            let hits = TermUses.occurrences(of: place.standing, in: text)
                .filter { hit in !taken.contains { $0.overlaps(hit) } }
            guard let at = hits.min(by: {
                abs(words(before: $0.lowerBound) - place.word)
                    < abs(words(before: $1.lowerBound) - place.word)
            }) else {
                Log.write("selector: \"\(place.standing)\" is not in the text that"
                    + " landed; not asked")
                continue
            }
            taken.append(at)
            found.append(Placed(range: at, open: place))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The text with each answered place written the way it was answered.
    ///
    /// The same walk `VocabularyPass.settling` does, and for the same reason:
    /// everything outside a place survives exactly as it arrived, newlines and
    /// double spaces included. A word split and rejoined on single spaces
    /// would lose both.
    ///
    /// `answers` may be shorter than `places` — that is a run that ended
    /// before every question was answered. Those places keep what stands
    /// there, which is the text the pipeline returned.
    ///
    /// - Parameter refusing: what to write when the answer is option 1. It is
    ///   a closure because refusing a term can change the spelling of the
    ///   phrase that goes back — see `AppDelegate.refusedSpelling` — and that
    ///   needs the vocabulary and a tagger this type has no business holding.
    static func written(
        _ places: [Placed], answers: [Int], in text: String,
        refusing: (Placed) -> String
    ) -> (text: String, words: [Written]) {
        var out = "", cursor = text.startIndex
        var written: [Written] = []
        for (index, place) in places.enumerated() {
            out += text[cursor..<place.range.lowerBound]
            let word = index < answers.count && answers[index] == 1
                ? refusing(place)
                : place.open.standing
            // Where it ended up, not where it was asked about. A place after
            // one that got longer or shorter has moved, and the trace's whole
            // job is to say which occurrence this was.
            let from = out.count
            out += word
            written.append(Written(word: word, range: from ..< out.count))
            cursor = place.range.upperBound
        }
        return (out + text[cursor...], written)
    }

    /// A word as it was written, and where it sits in the text that shipped.
    struct Written: Equatable {
        let word: String
        /// Character offsets, the unit `Trace.edit` already writes — see
        /// `EditWatch.asHeard`. Two `range` fields in one trace file measuring
        /// in different units is a trap for whatever reads them together.
        let range: Range<Int>
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byRun: [Int: [Open]] = [:]

    /// Keep this run's open places. Called off the main thread, from the stage.
    ///
    /// An empty list clears the run rather than leaving what was there. A
    /// config may list `vocabulary` twice, and then the last stage to run is
    /// the one that says what is still open — a stage that settles everything
    /// has to be able to take the question away.
    static func record(run: Int, _ places: [Open]) {
        lock.lock()
        if places.isEmpty { byRun.removeValue(forKey: run) } else { byRun[run] = places }
        lock.unlock()
    }

    /// The places, and they are gone. One dictation asks once.
    static func take(for run: Int) -> [Open] {
        lock.lock()
        defer { lock.unlock() }
        return byRun.removeValue(forKey: run) ?? []
    }

    /// This dictation is over, however it ended. Called from `dictationEnded`,
    /// which is what keeps this from growing on the runs nobody asks about —
    /// a cancelled dictation, or a spoken command that never reaches the pill.
    static func forget(_ run: Int) {
        lock.lock()
        byRun.removeValue(forKey: run)
        lock.unlock()
    }
}
