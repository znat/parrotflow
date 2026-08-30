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
/// Every `word. Capital` boundary in the finished transcript is scored by
/// `SentenceProbe` — one masked position, `log P(".") - log P(" <next word>")`
/// — and two thresholds decide:
///
///     score < join_below                    join, and say nothing
///     join_below <= score < offer_below     offer the join, do not write it
///     score >= offer_below                  leave it alone
///
/// Joining removes the period and lowercases the word after it.
///
/// English only. The model is English-only, and the same probe measured on
/// `cservan/french-modernbert-large` and `-base` scores near chance — 0.67 and
/// 0.58 AUC against 0.96 for English. There is no French model to switch to.
///
/// Fails open everywhere. No cached model, a probe that throws, a boundary it
/// cannot read: the text arrives as it was. A sentence in two halves is a
/// worse transcript; a rewrite nobody asked for costs the words themselves.
@available(macOS 14, *)
actor SentenceJoin {

    static let shared = SentenceJoin()

    /// What one pass did, for the pipeline to read.
    ///
    /// `offer` is the tier that does not write. It is a log line and a count
    /// today: the vocabulary pass's `proposals` road is keyed by term and ends
    /// at a judge that argues about names, and the pill's offer is a row of
    /// transform chips. Neither carries a boundary, so this publishes the
    /// count and waits for a consumer rather than forcing one.
    struct Outcome: Sendable {
        let text: String
        let readings: [Reading]

        func count(_ tier: Tier) -> Int { readings.filter { $0.tier == tier }.count }

        static func unchanged(_ text: String) -> Outcome {
            Outcome(text: text, readings: [])
        }
    }

    /// One boundary, scored. `change` reads `parrot. At -> parrot at`.
    struct Reading: Sendable {
        let change: String
        /// Where the period is in the text this pass was handed. Two boundaries
        /// can read the same, so the trace needs the position to tell them
        /// apart.
        let at: Int
        let score: Double
        let tier: Tier
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

    /// The masked language model, once per process, and only if it is already
    /// on disk. `Transcriber.warmSentenceModel` fetches it in the background
    /// after the first English dictation; nothing here waits for that.
    private var loaded: SentenceProbe?
    private var failed = false

    private func probe() async -> SentenceProbe? {
        if let loaded { return loaded }
        guard !failed, SentenceModel.isCached else { return nil }
        do {
            loaded = try await SentenceProbe.load()
        } catch {
            failed = true
            Log.write("sentences: no probe (\(error.localizedDescription)); left as decoded")
        }
        return loaded
    }

    /// The transcript with the false periods taken out.
    ///
    /// Every boundary is scored against the text as it arrived, not against
    /// the text as it is being rebuilt. A join only removes a period, so the
    /// window a later boundary reads is the same words either way.
    func apply(to text: String, config: Config) async -> Outcome {
        let settings = config.transcription.sentences
        guard settings.enabled else { return .unchanged(text) }
        let found = Self.boundaries(in: text)
        guard !found.isEmpty, let probe = await probe() else { return .unchanged(text) }
        let terms = Array(config.vocabulary.terms.keys)

        var readings: [Reading] = []
        var rebuilt = ""
        var cursor = text.startIndex
        for boundary in found {
            let word = String(text[boundary.next])
            let score: Double
            do {
                score = try probe.read(
                    left: String(text[..<boundary.period]),
                    right: String(text[boundary.next.lowerBound...])
                ).score
            } catch {
                Log.write(
                    "sentences: \(word.debugDescription) could not be read"
                        + " (\(error.localizedDescription)); left as decoded"
                )
                continue
            }
            let (whole, offset) = Self.joining(text, at: boundary)
            let now = Self.written(word, in: whole, at: offset, terms: terms)
            let before = String(
                text[..<boundary.period].reversed().prefix { !$0.isWhitespace }.reversed()
            )
            let tier = Tier(of: score, by: settings)
            let change = "\(before). \(word) -> \(before) \(now)"
            Log.write(String(format: "sentences: %@ %.2f %@", change, score, tier.rawValue))
            readings.append(Reading(
                change: change,
                at: text.distance(from: text.startIndex, to: boundary.period),
                score: score, tier: tier
            ))

            if tier == .join {
                rebuilt += text[cursor..<boundary.period]
                rebuilt += text[text.index(after: boundary.period)..<boundary.next.lowerBound]
                rebuilt += now
                cursor = boundary.next.upperBound
            }
        }
        return Outcome(text: rebuilt + text[cursor...], readings: readings)
    }

    /// Which of the three a score falls in.
    enum Tier: String {
        case join, offer, leave

        init(of score: Double, by settings: Config.Transcription.Sentences) {
            if score < settings.joinBelow {
                self = .join
            } else if score < settings.offerBelow {
                self = .offer
            } else {
                self = .leave
            }
        }
    }
}
