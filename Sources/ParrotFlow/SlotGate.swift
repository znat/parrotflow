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
/// The rules, in the order they run:
///
///     the slot accepts a name, and the word is rank 0    apply
///     the slot refuses a name                            decline
///     anything else                                      judge
///
/// **Slot POS.** Mask the heard word, take the ten most likely fillers, put
/// each back in the sentence and tag it. The modal tag is what the slot wants.
/// Tagging the word that is already there says nothing — it describes a word
/// that may be wrong. Masking asks the sentence instead. It is the only signal
/// that catches `Mirza's -> Mirza`: "waiting for ___ thoughts" predicts
/// `second, my, your, any, some, more, the, first`, and a bare name does not
/// go in a determiner slot.
///
/// **Rank 0.** The heard word is the weakest place in its sentence: no word
/// surprises the model more, and no two-word window more than the one it sits
/// on. One forward pass per word, each word read by its first BPE piece — see
/// `weakest`.
///
/// **ANDed, cheapest first.** An AND already fails once the POS refuses, and
/// the POS is one pass against the rank's one per word, so the rank is not
/// computed then.
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
        case apply, decline, judge
    }

    /// Tags a name can stand in. Rule 4.
    static let hosts: Set<String> = ["Noun", "Adjective", "Pronoun"]

    /// Tags a name cannot stand in. Rule 6.
    static let blocks: Set<String> = ["Verb", "Adverb", "Preposition"]

    /// How many fillers vote on what the slot wants.
    static let fillers = 10

    let probe: SentenceProbe

    struct Reading {
        /// The modal tag of the fillers, or "" when nothing tagged.
        let tag: String
        /// How far the span is from being the weakest place in the sentence —
        /// see `weakest`. Absent when the POS refused and the rank was skipped.
        let rank: Int?
        let windows: Int
        let route: Route
    }

    /// Where one proposal should go. `range` is a range in `text`.
    func read(in text: String, at range: Range<String.Index>) throws -> Reading {
        let (words, span) = Self.sentence(around: range, in: text)
        guard !span.isEmpty, span.upperBound <= words.count else {
            return Reading(tag: "", rank: nil, windows: 0, route: .judge)
        }

        let tag = try wants(words, at: span)
        guard Self.hosts.contains(tag) else {
            return Reading(
                tag: tag, rank: nil, windows: 0,
                route: Self.blocks.contains(tag) ? .decline : .judge
            )
        }
        let (rank, windows) = try weakest(words, at: span)
        return Reading(
            tag: tag, rank: rank, windows: windows,
            route: rank == 0 ? .apply : .judge
        )
    }

    // MARK: - Rule 4 and rule 6, the slot's part of speech

    /// The modal tag of the most likely fillers of the masked span.
    ///
    /// Ties go to the more likely filler, because the fillers arrive sorted.
    func wants(_ words: [String], at span: Range<Int>) throws -> String {
        try tagged(words, at: span).0
    }

    /// What the slot itself makes of two readings of it.
    ///
    /// The masked slot is a distribution over the whole vocabulary, and the
    /// rule reads two things off it today: the modal tag of its top ten, and
    /// where the word present sits in a ranking of the whole sentence. It
    /// never asks the one question the slot can answer directly — is the word
    /// that is there more likely here than the word somebody wants to put in
    /// its place.
    ///
    /// Returned for `--word-gate` to print. Nothing decides on it yet.
    func weighs(
        _ words: [String], at span: Range<Int>, against term: String
    ) throws -> (heard: Double, term: Double)? {
        let (left, right) = Self.masked(words, at: span)
        let slot = try probe.at(left: left, right: right)
        let lead = left.isEmpty ? "" : " "
        guard let here = probe.tokenizer.firstID(of: lead + Self.bare(words[span.lowerBound])),
              let there = probe.tokenizer.firstID(of: lead + Self.bare(term))
        else { return nil }
        return (slot.logProbability(of: here), slot.logProbability(of: there))
    }

    /// The same reading, with the words it was taken from.
    ///
    /// The rule keeps one tag out of ten guesses and throws the guesses away.
    /// They are what makes the tag readable — "Determiner" means nothing until
    /// you see `second, my, your, any, some` under it — so the diagnostic asks
    /// for both. Nothing decides on the words.
    func tagged(
        _ words: [String], at span: Range<Int>
    ) throws -> (String, [(word: String, tag: String)]) {
        let (left, right) = Self.masked(words, at: span)
        let slot = try probe.at(left: left, right: right)
        var seen: [(word: String, tag: String)] = []

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
            let named = Self.named(in: sentence, at: at, length: word.count) ?? tag
            seen.append((word, named == tag ? tag : "\(tag)/\(named)"))
        }
        var best = ""
        for tag in order where counts[tag, default: 0] > counts[best, default: 0] { best = tag }
        return (best, seen)
    }

    /// `.lexicalClass` and not `.nameTypeOrLexicalClass`. The question is what
    /// kind of slot this is, and a filler that happens to be a name would come
    /// back `PersonalName` rather than `Noun` and split the vote.
    /// The same tagging, asked for a name type first.
    ///
    /// `lexicalClass` collapses every proper noun into `Noun`, so the rule
    /// cannot tell "a name goes here" from "a thing goes here".
    /// `nameTypeOrLexicalClass` answers `PersonalName`, `PlaceName` or
    /// `OrganizationName` where it can. Printed by `--word-gate`; nothing
    /// decides on it.
    static func named(in sentence: String, at offset: Int, length: Int) -> String? {
        guard let from = sentence.index(
                sentence.startIndex, offsetBy: offset, limitedBy: sentence.endIndex),
              let to = sentence.index(from, offsetBy: length, limitedBy: sentence.endIndex)
        else { return nil }
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = sentence
        tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
        _ = to
        return tagger.tag(at: from, unit: .word, scheme: .nameTypeOrLexicalClass).0?.rawValue
    }

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

    // MARK: - Rule 5, the weakest window

    /// How far the span is from being the weakest place in its sentence.
    ///
    /// One forward pass per word: mask it, read the log-probability of the word
    /// that is there. Two rankings come off that one array — the words, and the
    /// adjacent pairs summed — and the rank returned is the worse of the two.
    /// Rank 0 therefore means both: no word surprises the model more than the
    /// span, and no pair more than the pair the span sits on.
    ///
    /// A word is scored by its **first BPE piece**, not by all of them. One
    /// masked position holds one token, so the rest of a multi-piece word would
    /// need a pass each with the pieces before it revealed — a different and
    /// far more expensive question. `SentenceProbe.read` reads the word after a
    /// boundary the same way. It costs little here: the rare piece of a
    /// misheard name is the first one, and this is a ranking, so every word in
    /// the sentence is measured on the same footing.
    ///
    /// The window alone is not enough. On a sentence of ordinary words the
    /// weakest pair is decided by noise, and it landed on the span in three of
    /// the 50 cases where the span was the word the speaker said. Adding the
    /// word ranking takes those three out and costs nothing else.
    func weakest(_ words: [String], at span: Range<Int>) throws -> (rank: Int, windows: Int) {
        try ranked(words, at: span).0
    }

    /// The same walk, with the numbers it decided on.
    ///
    /// The rank is a place in a queue and says nothing about the distance to
    /// the word behind it. Two sentences can both put a name first and mean
    /// very different things by it — a nonsense spelling sits nats below
    /// everything else, a rare proper noun sits a fraction below its
    /// neighbour. Only the scores tell those apart, and the rule cannot: it
    /// reads the place and not the gap.
    ///
    /// Returned for `--word-gate` to print. Nothing decides on it.
    func ranked(
        _ words: [String], at span: Range<Int>
    ) throws -> ((rank: Int, windows: Int), [(word: String, score: Double)]) {
        guard words.count >= 2 else { return ((Int.max, 0), []) }
        var scores: [Double] = []
        for index in words.indices {
            let (left, right) = Self.masked(words, at: index..<(index + 1))
            let slot = try probe.at(left: left, right: right)
            let bare = Self.bare(words[index])
            let id = probe.tokenizer.firstID(of: (index == 0 ? "" : " ") + bare)
            scores.append(id.map { slot.logProbability(of: $0) } ?? -.infinity)
        }

        let byWord = scores.indices.sorted { scores[$0] < scores[$1] }
        let word = byWord.firstIndex { span.contains($0) } ?? Int.max

        let windows = (0..<(words.count - 1)).map { scores[$0] + scores[$0 + 1] }
        let byWindow = windows.indices.sorted { windows[$0] < windows[$1] }
        // A window holds the span when either of its two words is in it.
        let pair = byWindow.firstIndex { span.contains($0) || span.contains($0 + 1) } ?? Int.max
        return (
            (max(word, pair), windows.count),
            byWord.map { (words[$0], scores[$0]) }
        )
    }

    // MARK: - The sentence, as words

    /// The sentence `range` sits in, split into words, and which of them the
    /// range covers.
    ///
    /// The sentence and not the whole transcript: "its sentence" is what the
    /// rank is measured against, and a second sentence only adds windows the
    /// span can never win.
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
