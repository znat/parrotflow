import Foundation
import NaturalLanguage

/// Can a name stand where this word stands? Asked of the sentence, not of the
/// word.
///
/// The judge is a model call of about 900 ms and every proposal the lexical
/// gate does not settle goes to it. This settles some of them with the masked
/// language model `SentenceProbe` already loads: one forward pass to see what
/// the slot wants, and one per word only when that pass says a name could go
/// there. A pass is about 8 ms at sequence length 64.
///
/// One rule:
///
///     the slot refuses a name    decline
///     anything else              judge
///
/// **Slot POS.** Mask the heard word, take the ten most likely fillers, put
/// each back in the sentence and tag it. The modal tag is what the slot wants.
/// Tagging the word that is already there says nothing — it describes a word
/// that may be wrong. Masking asks the sentence instead. It is the only signal
/// that catches `Mirza's -> Mirza`: "waiting for ___ thoughts" predicts
/// `second, my, your, any, some, more, the, first`, and a bare name does not
/// go in a determiner slot.
///
/// **There was a second rule and it is gone.** It wrote a name when the span
/// was the weakest-reading place in its sentence. It asked whether a word was
/// *unexpected* where the question is whether it is *wrong*, and a rare proper
/// noun is both. Measured over the 150 real decisions of the vocabulary bench
/// it wrote 27 names and 17 were wrong — `ghostly` to `Ghostty` four times,
/// `bedrock` to `Redrock` twice, `verbatim` to `Mirza`, `gamma` to `Gemma`.
/// Its recorded 47/50 was real and came from a set holding none of those.
///
/// **The decline runs last, after the lexical gate.** `Vocabulary.slotRoute`
/// is only asked about a proposal that gate left open. The gate decides on
/// evidence the slot cannot see — the sound, and a spelling neither word list
/// knows — and a slot must not overrule it.
///
/// **`Determiner` is not blocked.** A determiner slot is a modifier position
/// and names do sit there — `cloud code`, `bedrock principles`. Blocking it
/// costs a wrong decline.
///
/// Measured over the 50 English cases of `tests/judge-cases.yaml` by
/// `scripts/check-slot-gate.sh`: 15 auto-applied, 14 declined, 21 left for the
/// judge, and no error of either kind.
@available(macOS 14, *)
struct SlotGate {

    enum Route: String {
        case decline, judge
    }

    /// Tags a name cannot stand in.
    static let blocks: Set<String> = ["Verb", "Adverb", "Preposition"]

    /// How many fillers vote on what the slot wants.
    static let fillers = 10

    let probe: SentenceProbe

    struct Reading {
        /// The modal tag of the fillers, or "" when nothing tagged.
        let tag: String
        let route: Route
    }

    /// Where one proposal should go. `range` is a range in `text`.
    func read(in text: String, at range: Range<String.Index>) throws -> Reading {
        let (words, span) = Self.sentence(around: range, in: text)
        guard !span.isEmpty, span.upperBound <= words.count else {
            return Reading(tag: "", route: .judge)
        }
        let tag = try wants(words, at: span)
        return Reading(tag: tag, route: Self.blocks.contains(tag) ? .decline : .judge)
    }

    // MARK: - Rule 4 and rule 6, the slot's part of speech

    /// The modal tag of the most likely fillers of the masked span.
    ///
    /// Ties go to the more likely filler, because the fillers arrive sorted.
    func wants(_ words: [String], at span: Range<Int>) throws -> String {
        let (left, right) = Self.masked(words, at: span)
        let slot = try probe.at(left: left, right: right)

        var counts: [String: Int] = [:]
        var order: [String] = []
        for filler in slot.top(Self.fillers) {
            let word = filler.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, word.contains(where: \.isLetter) else { continue }
            let sentence = left + (left.isEmpty ? "" : " ") + word + right
            let at = left.isEmpty ? 0 : left.count + 1
            guard let tag = Self.tag(in: sentence, at: at, length: word.count) else { continue }
            if counts[tag] == nil { order.append(tag) }
            counts[tag, default: 0] += 1
        }
        var best = ""
        for tag in order where counts[tag, default: 0] > counts[best, default: 0] { best = tag }
        return best
    }

    /// `.lexicalClass` and not `.nameTypeOrLexicalClass`. The question is what
    /// kind of slot this is, and a filler that happens to be a name would come
    /// back `PersonalName` rather than `Noun` and split the vote.
    private static func tag(in sentence: String, at offset: Int, length: Int) -> String? {
        guard let from = sentence.index(
                sentence.startIndex, offsetBy: offset, limitedBy: sentence.endIndex),
              let to = sentence.index(from, offsetBy: length, limitedBy: sentence.endIndex)
        else { return nil }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
        return tagger.tag(at: from, unit: .word, scheme: .lexicalClass).0?.rawValue
    }

    // MARK: - The sentence, as words

    /// The sentence `range` sits in, split into words, and which of them the
    /// range covers.
    ///
    /// The sentence and not the whole transcript: what the slot wants is
    /// decided by the words around the span, and a second sentence only puts
    /// words in the window that were never near it.
    static func sentence(
        around range: Range<String.Index>, in text: String
    ) -> (words: [String], span: Range<Int>) {
        var found = text.startIndex..<text.endIndex
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]
        ) { _, at, _, stop in
            if at.contains(range.lowerBound) || at.lowerBound == range.lowerBound {
                found = at
                stop = true
            }
        }
        // A span that straddles two sentences is measured against the whole
        // text rather than against half of itself.
        if range.upperBound > found.upperBound { found = text.startIndex..<text.endIndex }

        var words: [String] = []
        var span = 0..<0
        var cursor = found.lowerBound
        while cursor < found.upperBound {
            guard let start = text[cursor..<found.upperBound]
                .firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = text[start..<found.upperBound].firstIndex(where: \.isWhitespace)
                ?? found.upperBound
            if start < range.upperBound && end > range.lowerBound {
                let from = span.isEmpty ? words.count : span.lowerBound
                span = from..<(words.count + 1)
            }
            words.append(String(text[start..<end]))
            cursor = end
        }
        return (words, span)
    }

    /// The words either side of the span, as `SentenceProbe.at` wants them:
    /// the left with no trailing space, the right carrying its own leading one.
    ///
    /// The span's trailing punctuation stays on the right. "cancel." masked
    /// whole takes the full stop with it, and the slot then reads as the middle
    /// of a sentence rather than the end of one.
    static func masked(_ words: [String], at span: Range<Int>) -> (left: String, right: String) {
        let head = words[..<span.lowerBound].suffix(SentenceProbe.radius)
        let tail = words[span.upperBound...].prefix(SentenceProbe.radius)
        let marks = String(words[span.upperBound - 1].suffix(
            words[span.upperBound - 1].count - bare(words[span.upperBound - 1]).count
        ))
        let rest = tail.isEmpty ? "" : " " + tail.joined(separator: " ")
        return (head.joined(separator: " "), marks + rest)
    }

    /// The word without the punctuation it ends on.
    static func bare(_ word: String) -> String {
        String(word.reversed().drop { !$0.isLetter && !$0.isNumber }.reversed())
    }
}
