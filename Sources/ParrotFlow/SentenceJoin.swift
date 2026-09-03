import Foundation
import NaturalLanguage

/// Puts back together a sentence a pause cut in two.
///
/// The transcriber writes a period wherever you stop for breath, and
/// capitalises the word after it. One sentence becomes two:
///
///     said     "you should see a parrot at the top right of your screen"
///     written  "You should see a parrot. At the top right of your screen."
///
/// Every `word. Capital` boundary in the finished transcript is read three
/// ways by `SentenceReadings` — with a period, with a comma, and with nothing
/// at all — and the reading the language model scores highest is the one that
/// is written. Nothing is compared to a threshold, so there is nothing to
/// calibrate. Where the joined reading wins, the period is removed and the
/// word after it is lowercased.
///
/// The thresholds this used to carry repaired 26% of the cuts. The choice
/// repairs 82%, and joins none of 172 real sentence endings.
///
/// English only. The reading is scored by an English base model, and the mark
/// set is English: French wants `:` where English does not.
///
/// Fails open everywhere. A model still downloading, a load that threw, a
/// boundary it cannot read: the text arrives as it was. A sentence in two
/// halves is a worse transcript; a rewrite nobody asked for costs the words
/// themselves.
@available(macOS 14, *)
actor SentenceJoin {

    static let shared = SentenceJoin()

    /// What one pass did, for the pipeline to read.
    struct Outcome: Sendable {
        let text: String
        let readings: [Reading]

        func count(_ tier: Tier) -> Int { readings.filter { $0.tier == tier }.count }

        static func unchanged(_ text: String) -> Outcome {
            Outcome(text: text, readings: [])
        }
    }

    /// One boundary, read every way. `change` reads `parrot. At -> parrot at`.
    struct Reading: Sendable {
        let change: String
        let scores: [SentenceReadings.Score]
        let winner: String

        var tier: Tier { winner == SentenceReadings.join ? .join : .leave }
    }

    /// The reading with the highest per-token score, or nil if there is none.
    ///
    /// First past the post over the order `SentenceReadings.readings` builds —
    /// the marks, then the join — so an exact tie leaves the boundary alone.
    static func winner(of scores: [SentenceReadings.Score]) -> SentenceReadings.Score? {
        scores.reduce(nil) { best, score in
            guard let best else { return score }
            return score.mean > best.mean ? score : best
        }
    }

    /// One `word. Capital` boundary: the period, and the word after it.
    struct Boundary {
        let period: String.Index
        let next: Range<String.Index>
    }

    /// Tags a capital must survive. A name stays a name once the period goes.
    static let names: Set<String> = ["PersonalName", "PlaceName", "OrganizationName"]

    // MARK: - Finding the boundaries

    /// Every place a period is followed by a capitalised word.
    ///
    /// Three things that look like one and are not. A period inside a run of
    /// them is an ellipsis. A period after a single letter is an initial —
    /// "J. Smith". A period after anything but a letter or a digit is closing
    /// something rather than ending a sentence.
    static func boundaries(in text: String) -> [Boundary] {
        var found: [Boundary] = []
        var cursor = text.startIndex
        while let period = text[cursor...].firstIndex(of: ".") {
            cursor = text.index(after: period)
            guard period > text.startIndex, cursor < text.endIndex, text[cursor] != "." else {
                continue
            }
            let word = text[..<period].reversed().prefix { $0.isLetter || $0.isNumber }
            guard word.count > 1 else { continue }

            var start = cursor
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
            guard start > cursor, start < text.endIndex, text[start].isUppercase else { continue }
            let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            found.append(Boundary(period: period, next: start..<end))
            cursor = end
        }
        return found
    }

    // MARK: - The capital, once the period is gone

    /// The next word as it should be written with no period in front of it.
    ///
    /// Not every capital after a period is there because of the period. "I
    /// will ask him. Nathan knows the answer" must not become "ask him nathan
    /// knows", so the rule asks for a reason to lowercase rather than a reason
    /// to keep. Four say keep:
    ///
    ///   - `I`, and every contraction that starts with it.
    ///   - a word written in capitals throughout — `API`, `CI`.
    ///   - `PersonalName`, `PlaceName` or `OrganizationName` from `NLTagger`.
    ///   - a word `NLTagger` gives no lemma for. The lexicon does not know it,
    ///     and a capitalised word the lexicon has never seen is a name it has
    ///     not been told about. This is what catches `ParrotFlow`, which the
    ///     tagger calls a plain `Noun`.
    ///
    /// A vocabulary term is asked before any of that. Those are exactly the
    /// words this speaker uses and the lexicon does not, and a term that is
    /// also an English word — `Compass` — is the one case the lemma rule
    /// cannot see.
    ///
    /// Measured over `tests/sentence-case-cases.json` by
    /// `scripts/check-sentence-case.sh`. No model, so it runs in CI.
    ///
    /// `joined` is the text with this period already removed, and `at` is
    /// where the word starts in it. The word is tagged mid-sentence rather
    /// than at the head of one: with the period still in place the same set
    /// scored 20 of its first 24 cases, and without it 21.
    static func written(
        _ word: String, in joined: String, at offset: Int, terms: [String]
    ) -> String {
        let bare = String(word.prefix { $0.isLetter })
        guard let first = word.first, first.isUppercase, !bare.isEmpty else { return word }
        guard bare != "I", bare.count == 1 || bare != bare.uppercased() else { return word }
        guard !terms.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) else {
            return word
        }
        guard let from = joined.index(
            joined.startIndex, offsetBy: offset, limitedBy: joined.endIndex
        ) else { return word }

        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        tagger.string = joined
        tagger.setLanguage(.english, range: joined.startIndex..<joined.endIndex)
        let tag = tagger.tag(at: from, unit: .word, scheme: .nameTypeOrLexicalClass).0?.rawValue
        guard !Self.names.contains(tag ?? "") else { return word }
        let lemma = tagger.tag(at: from, unit: .word, scheme: .lemma).0?.rawValue ?? ""
        guard !lemma.isEmpty else { return word }
        return word.prefix(1).lowercased() + word.dropFirst()
    }

    /// The whole text with one period taken out, and where the word after it
    /// then starts. Both halves of what `written` needs to tag.
    static func joining(_ text: String, at boundary: Boundary) -> (text: String, offset: Int) {
        var joined = text
        joined.remove(at: boundary.period)
        // The period sits before the word, so removing it moves the word one
        // character left and nothing else moves at all.
        return (joined, text.distance(from: text.startIndex, to: boundary.next.lowerBound) - 1)
    }

    // MARK: - The pass

    /// The transcript with the false periods taken out.
    ///
    /// Every boundary is scored against the text as it arrived, not against
    /// the text as it is being rebuilt. A join only removes a period, so the
    /// window a later boundary reads is the same words either way.
    ///
    /// Nothing here waits for the model. A dictation that arrives before the
    /// weights are in memory keeps its boundaries and starts the load, so the
    /// first dictation after a launch pays nothing and the second is repaired.
    func apply(to text: String, config: Config) async -> Outcome {
        let settings = config.transcription.sentences
        guard settings.enabled else { return .unchanged(text) }
        let found = Self.boundaries(in: text)
        guard !found.isEmpty else { return .unchanged(text) }
        guard await SentenceReadings.shared.isLoaded else {
            await SentenceReadings.shared.warm()
            Log.write("sentences: \(found.count) boundary(s) left as decoded;"
                + " the model is not in memory yet")
            return .unchanged(text)
        }
        let terms = Array(config.vocabulary.terms.keys)

        var readings: [Reading] = []
        var rebuilt = ""
        var cursor = text.startIndex
        for boundary in found {
            let word = String(text[boundary.next])
            let started = DispatchTime.now().uptimeNanoseconds
            let scores: [SentenceReadings.Score]
            do {
                scores = try await SentenceReadings.shared.read(
                    left: String(text[..<boundary.period]),
                    right: String(text[boundary.next.lowerBound...]),
                    marks: settings.marks
                )
            } catch {
                Log.write(
                    "sentences: \(word.debugDescription) could not be read"
                        + " (\(error.localizedDescription)); left as decoded"
                )
                continue
            }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            guard let best = Self.winner(of: scores) else { continue }
            let (whole, offset) = Self.joining(text, at: boundary)
            let now = Self.written(word, in: whole, at: offset, terms: terms)
            let before = String(
                text[..<boundary.period].reversed().prefix { !$0.isWhitespace }.reversed()
            )
            let change = "\(before). \(word) -> \(before) \(now)"
            let listed = scores
                .map { String(format: "%@ %.2f", $0.key, $0.mean) }
                .joined(separator: "  ")
            Log.write(String(
                format: "sentences: %@ %@ [%@] %.0fms",
                change, best.key, listed, milliseconds
            ))
            readings.append(Reading(change: change, scores: scores, winner: best.key))

            if best.key == SentenceReadings.join {
                rebuilt += text[cursor..<boundary.period]
                rebuilt += text[text.index(after: boundary.period)..<boundary.next.lowerBound]
                rebuilt += now
                cursor = boundary.next.upperBound
            }
        }
        return Outcome(text: rebuilt + text[cursor...], readings: readings)
    }

    /// What a boundary came to. There is no middle tier: an argmax has no
    /// threshold to hedge with, so a boundary is either joined or left.
    enum Tier: String {
        case join, leave
    }
}
