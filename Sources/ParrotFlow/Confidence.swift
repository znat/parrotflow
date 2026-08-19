import SwiftUI

/// How sure the decoder was of each word, coloured onto the sentence.
///
/// **There is no published threshold to read this against.** Parakeet emits one
/// softmax probability per token and says nothing about what a value means;
/// FluidAudio averages them into `ASRResult.confidence` and documents only the
/// range. NVIDIA's own guidance for NeMo is that a raw probability is a weak
/// correctness signal and that the operating point has to be found on your own
/// data.
///
/// So the bands below are percentiles of this machine's own archive rather than
/// anybody's recommendation: 184,146 words over 15,446 dictations in
/// `trace.jsonl`, where the median word scores 0.995 and 68% sit at 1.0. A ramp
/// anchored on the raw 0–1 scale would paint almost the whole sentence white and
/// show nothing.
enum Confidence {

    /// A word of the finished sentence and what the decoder scored it.
    struct Word: Equatable {
        let text: String
        /// Nil where no decoded word became this one — a figure the numbers
        /// stage spelled out, a word a substitution inserted. Those have no
        /// reading of their own and must not borrow one.
        let score: Float?
    }

    // MARK: - The bands

    /// p25. Above this a word is as sure as three quarters of everything ever
    /// dictated here, and stays white.
    static let sure: Float = 0.89
    /// p10.
    static let watch: Float = 0.60
    /// p1. At and below it the word is as unsure as the worst one in a hundred,
    /// and the colour stops moving.
    static let doubtful: Float = 0.35

    /// The white end of the ramp. Not pure white: the pill's own lettering is
    /// not, and a word brighter than the surface it sits on reads as lit rather
    /// than as ordinary.
    static let clear = Color(white: 0.93)

    /// White for sure, then amber, then scarlet — the plumage in the order the
    /// feathers run, so the sentence uses the same colours as everything else.
    static func tint(_ score: Float?) -> Color {
        guard let score else { return Color.white.opacity(0.32) }
        return ramp(score, sure: sure, watch: watch, doubtful: doubtful)
    }

    /// The ramp itself, taking the three anchors it runs between. A word and
    /// the whole utterance are scored on scales that move very differently, so
    /// they share the colours and not the numbers.
    private static func ramp(
        _ score: Float, sure: Float, watch: Float, doubtful: Float
    ) -> Color {
        if score >= sure { return clear }
        if score >= watch {
            return Parrot.mix(clear, Parrot.amber, Double((sure - score) / (sure - watch)))
        }
        if score >= doubtful {
            return Parrot.mix(
                Parrot.amber, Parrot.scarlet, Double((watch - score) / (watch - doubtful))
            )
        }
        return Parrot.scarlet
    }

    /// The sentence as one run of text per word, each in its own colour.
    ///
    /// Concatenated `Text` rather than a row of views, so the line breaks where
    /// a paragraph would break and the pill can hold a long dictation.
    static func sentence(_ words: [Word]) -> Text {
        words.enumerated().reduce(Text(verbatim: "")) { line, item in
            let gap = item.offset > 0 ? Text(verbatim: " ") : Text(verbatim: "")
            return line + gap
                + Text(verbatim: item.element.text).foregroundStyle(tint(item.element.score))
        }
    }

    // MARK: - The whole utterance

    /// What the decoder scored the whole utterance, for under the words.
    ///
    /// This is `ASRResult.confidence`, FluidAudio's mean over the tokens. It is
    /// not the sentence's worst word and does not follow one: over the 16,513
    /// dictations in the archive it sits at 0.83 at p10 and 0.93 at the median,
    /// and of the dictations holding a word below `watch` only 13% fall under
    /// its own p10. It says how the decode went on average.
    ///
    /// Two decimals.
    static func overall(_ score: Float) -> String {
        String(format: "%.2f", score)
    }

    /// The utterance's own bands, percentiles of the same 16,513 dictations:
    /// p25, p10, p1 of `asr.confidence` itself.
    ///
    /// Its own numbers rather than the word ones, because a mean over every
    /// token in a sentence moves in a far narrower range than one word does.
    /// Read against the word bands, 3 dictations in 4 would print white and
    /// the colour would say nothing.
    static let utteranceSure: Float = 0.89
    static let utteranceWatch: Float = 0.83
    static let utteranceDoubtful: Float = 0.73

    /// The same ramp as the words, on the utterance's anchors. So white is a
    /// decode as good as the best three quarters, and scarlet is one as bad as
    /// the worst in a hundred — the same sentence the colour tells above.
    static func overallTint(_ score: Float) -> Color {
        ramp(score, sure: utteranceSure, watch: utteranceWatch, doubtful: utteranceDoubtful)
    }

    // MARK: - What the offer says

    /// Everything the offer knows about how the decode went.
    ///
    /// One value rather than three arguments: the pill's height and width are
    /// computed from all of it at once, and two of the three arrive together or
    /// not at all.
    struct Reading: Equatable {
        /// The dictation word by word. Empty unless `feedback.confidence` is
        /// on, and empty is what keeps the pill its old shape.
        var words: [Word] = []
        /// The decoder's score for the whole utterance. Drawn under the words,
        /// so it only shows with them.
        var overall: Float?
        /// Why this dictation is worth a second look. Nil when it is not.
        /// Drawn whether or not the words are, because it is one line and it is
        /// the half that is worth having without asking for it.
        var warning: String?
        /// True once a Return has been taken rather than typed. The same pill,
        /// asking rather than telling — see `Confidence.stopped`.
        var stopped = false

        var isEmpty: Bool { words.isEmpty && warning == nil }
    }

    /// Whether the words that landed may not be the words that were said.
    ///
    /// Both thresholds have to trip, not either. They are two views of the same
    /// clip and each is wrong on its own: a mean over every token stays high
    /// through one mangled name, and one low word is ordinary — a quarter of
    /// all dictations here hold one, most of them a clipped `the` or a trailing
    /// `uh` that changes nothing. A decode that is bad *overall* and holds a
    /// word the decoder could not place is the one that is worth stopping for.
    ///
    /// Words the vocabulary pass wrote are not counted. They carry the score of
    /// the decode they replaced — that is what `read` does, and it is right for
    /// the colours — but that score is low by definition, because a shaky
    /// decode is what made the pass fire. Measured over 3,724 substitutions
    /// here, 38.8% of the words they replaced were under 0.60 against 9.9% of
    /// words generally. Counting them would warn loudest about the names the
    /// app has just fixed.
    ///
    /// Strictly below, so a threshold of zero turns the warning off.
    static func warning(
        _ reading: [Word], utterance: Float?, vocabulary: [String],
        sentenceBelow: Float, wordBelow: Float
    ) -> String? {
        guard let utterance, utterance < sentenceBelow else { return nil }
        let written = Set(
            vocabulary.flatMap { $0.split(whereSeparator: \.isWhitespace) }.map { key(String($0)) }
        )
        let scored = reading.compactMap { word -> (String, Float)? in
            guard let score = word.score, !written.contains(key(word.text)) else { return nil }
            return (word.text, score)
        }
        guard let worst = scored.min(by: { $0.1 < $1.1 }), worst.1 < wordBelow else { return nil }
        return "This may not be what you said · \(worst.0)"
    }

    /// What the pill says when it has just eaten a Return.
    ///
    /// Not a question and not an apology. It says what was taken, and what to
    /// do to get it back, in that order — the key is already pressed by the
    /// time this is read, so the first thing to establish is that it did not
    /// go through.
    static let stopped = "Enter held · check what was written, then press it again"

    // MARK: - Putting the scores back on the words

    /// What the decoder scored, carried onto the sentence that came out of the
    /// pipeline.
    ///
    /// They are not the same list of words. Every stage after the decoder
    /// rewrites text the token timings index — the vocabulary pass replaces
    /// names, `numbers` spells figures out, substitutions fire — so the scores
    /// have to be matched back rather than zipped. Measured over the archive,
    /// 93.5% of decoded words reach the final text unchanged, and 44% of
    /// dictations are untouched end to end.
    ///
    /// Matched words take their own score. A word the pipeline rewrote takes the
    /// lowest score of the decoded words it replaced, because that rewrite is
    /// about the same piece of audio — a name corrected from a shaky decode is
    /// exactly the word worth colouring. Anything with no decoded word behind it
    /// takes none.
    static func read(_ heard: [Trace.Word], into text: String) -> [Word] {
        let written = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !written.isEmpty else { return [] }
        // The match below is quadratic in the two lengths. A minute of dictation
        // is about 150 words, so this only ever trips on something that is not a
        // dictation, and a sentence with no colour beats a stalled pill.
        guard !heard.isEmpty, heard.count <= 400, written.count <= 400 else {
            return written.map { Word(text: $0, score: nil) }
        }

        var scores = [Float?](repeating: nil, count: written.count)
        let pairs = anchors(heard.map { key($0.word) }, written.map(key))

        var lastHeard = -1
        var lastWritten = -1
        // The pairs, then one past the end of both, so the run after the last
        // match is filled by the same loop that fills the runs between matches.
        for (h, w) in pairs + [(heard.count, written.count)] {
            let heardGap = (lastHeard + 1)..<min(h, heard.count)
            let writtenGap = (lastWritten + 1)..<min(w, written.count)
            if !heardGap.isEmpty, !writtenGap.isEmpty,
               let worst = heardGap.map({ heard[$0].confidence }).min() {
                for index in writtenGap { scores[index] = worst }
            }
            if h < heard.count, w < written.count { scores[w] = heard[h].confidence }
            lastHeard = h
            lastWritten = w
        }

        return written.enumerated().map { Word(text: $0.element, score: scores[$0.offset]) }
    }

    /// Case and punctuation are not what this is about. "Versal," and "versal"
    /// are the same decode; the pipeline capitalises and punctuates all the
    /// time, and matching on the raw string would call every sentence rewritten.
    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// The words the two lists agree on, in order — a longest common
    /// subsequence, returned as index pairs.
    private static func anchors(_ heard: [String], _ written: [String]) -> [(Int, Int)] {
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: written.count + 1), count: heard.count + 1
        )
        for h in stride(from: heard.count - 1, through: 0, by: -1) {
            for w in stride(from: written.count - 1, through: 0, by: -1) {
                table[h][w] = heard[h] == written[w]
                    ? table[h + 1][w + 1] + 1
                    : max(table[h + 1][w], table[h][w + 1])
            }
        }

        var pairs: [(Int, Int)] = []
        var h = 0
        var w = 0
        while h < heard.count, w < written.count {
            if heard[h] == written[w] {
                pairs.append((h, w))
                h += 1
                w += 1
            } else if table[h + 1][w] >= table[h][w + 1] {
                h += 1
            } else {
                w += 1
            }
        }
        return pairs
    }
}
