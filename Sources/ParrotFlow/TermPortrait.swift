import CryptoKit
import Foundation

/// What a term's confirmed sentences say about where it belongs.
///
/// Three numbers per term, computed from the sentences `TermUses` keeps:
///
///   - `centre`, the mean of the context vectors — every token of a sentence
///     except the term's own, so it describes the sentence and not the word;
///   - `tightness`, how close those sentences sit to that centre;
///   - `floor`, what a genuine use of this term scores against it, from
///     `floorMinimum` uses up.
///
/// A new sentence is scored against the centre and divided by the tightness.
/// Above the floor, the rewrite is authorised.
///
/// A term that has been corrected out of one sentence gets a second centre
/// built the same way from those. Then there is no floor: the sentence is
/// written when it is closer to the first centre than to the second, and
/// refused when it is closer to the second. See `band`.
///
/// **Why divide by the tightness.** A portrait built from many varied sentences
/// has a centre further from everything, so the same cosine means less. Dividing
/// puts every term on one scale: 1.00 is "as typical of this term as its own
/// sentences are".
///
/// **Why the floor is a low quantile and not an average.** As a term collects
/// uses, a held-out one sits almost on top of the rest, so the average climbs
/// toward 1.00 while a genuinely new sentence stays near 0.96 and gets refused.
/// Measured on one term grown to 32 uses: the average makes 2 wrong decisions of
/// 5, the tenth percentile none.
///
/// This half authorises, and refuses when the sentence is far enough the other
/// way. `SlotReference` only refuses, and when the two disagree neither wins —
/// the reading is offered instead.
@available(macOS 14, *)
actor TermPortrait {

    static let shared = TermPortrait()

    /// How many confirmed uses a term needs before it has a centre at all.
    ///
    /// One. A single sentence is enough to compare against a counter-example.
    static let minimum = 1

    /// How many uses the floor path needs.
    ///
    /// The floor is a leave-one-out quantile, so it needs uses to leave out: at
    /// two the floor came out below every ordinary word, at three it holds. A
    /// term with no counter-example and fewer than this has no portrait, and
    /// the stage decides as it does today.
    static let floorMinimum = 3

    /// Where the floor is read off the leave-one-out scores.
    static let quantile = 0.10

    /// How many words either side of the span the portrait reads.
    ///
    /// It used to read whatever string it was handed, and `SentenceGate` hands
    /// it the whole transcript. So a dictation that mentioned the term earlier
    /// scored every later span as if the term belonged there — "I deployed the
    /// app on Vercel. I love visiting the Versailles Castle." scored the castle
    /// at 1.034 where the castle sentence alone scores 0.754. Not even a
    /// sentence boundary stopped it.
    ///
    /// Measured on the seeded Vercel portrait, the two spans of "I deploy my
    /// apps on Versal but I love visiting the Versailles Castle", which the
    /// whole string gets both wrong:
    ///
    ///     radius   Versailles (want refuse)   Versal (want write)
    ///     whole      1.019  writes            1.012  writes
    ///     5          0.833  refuses           1.010  writes
    ///     3          0.809  refuses           0.924  writes
    ///     2          0.824  refuses           0.890  nothing
    ///
    /// 2 is too tight — it drops a correct write on a clean sentence as well.
    /// `SlotProbe.radius` is 12 for the other test, which reads a mask and
    /// not a topic; this one is narrower because a topic changes inside a
    /// sentence and a mask does not.
    static let radius = 5

    /// The `radius` words either side of the span, never leaving its sentence.
    ///
    /// Both bounds are needed and neither alone is enough. The sentence stops a
    /// name said in one sentence from deciding the next — mention Vercel once
    /// and every later `Versailles` was overwritten. The radius cuts inside a
    /// sentence, where the sentence bound does nothing: "deployed on Versal but
    /// visiting the Versailles Castle" is one sentence holding two topics.
    ///
    /// Measured on the 20-case held-out set, each case also read with one
    /// earlier sentence about the same term in front of it:
    ///
    ///     window                     alone          with a lead-in
    ///     the whole text             18 / 1 wrong   10 / 10 wrong
    ///     radius only                18 / 1 wrong   14 /  5 wrong
    ///     radius and the sentence    18 / 1 wrong   18 /  1 wrong
    ///
    /// The last row is the same either way, which is the property wanted: what
    /// was said earlier no longer reaches the span at all. The one that stays
    /// wrong is wrong without a lead-in too, and is a thin portrait rather than
    /// a window.
    static func window(
        around range: Range<String.Index>, in text: String, radius: Int = TermPortrait.radius
    ) -> String {
        var bounds = text.startIndex ..< text.endIndex
        text.enumerateSubstrings(
            in: text.startIndex ..< text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, at, _, stop in
            if at.contains(range.lowerBound) || at.lowerBound == range.lowerBound {
                bounds = at
                stop = true
            }
        }
        // A span reaching past its own sentence is not one this can cut down.
        if range.upperBound > bounds.upperBound { bounds = text.startIndex ..< text.endIndex }

        var words: [Range<String.Index>] = []
        var holds: [Int] = []
        var cursor = bounds.lowerBound
        while cursor < bounds.upperBound {
            guard let from = text[cursor ..< bounds.upperBound]
                .firstIndex(where: { !$0.isWhitespace }) else { break }
            let to = text[from ..< bounds.upperBound].firstIndex(where: \.isWhitespace)
                ?? bounds.upperBound
            if from < range.upperBound && to > range.lowerBound { holds.append(words.count) }
            words.append(from ..< to)
            cursor = to
        }
        guard let first = holds.first, let last = holds.last else { return text }
        let lo = words[max(0, first - radius)].lowerBound
        let hi = words[min(words.count - 1, last + radius)].upperBound
        return String(text[lo ..< hi])
    }

    /// How far below the floor a sentence has to fall before the term is taken
    /// out rather than merely not written.
    ///
    /// The portrait was built to authorise only. It is the one test that tells
    /// `We host our databases on superbase` from `The rocket landed on the moon
    /// on its superbase` — 0.944 against 0.665 — and the one that tells
    /// `I deploy my app on Versal` from `I love visiting the Versailles Castle`
    /// — 1.001 against 0.690. Neither pair moves the slot test at all.
    ///
    /// 0.04 on the fourth dictation: 6 of 11 overwrites refused, 1 of 13
    /// correct writes lost. Chosen on that set, which was the last one held
    /// out, so it is a number to re-measure and not one to trust.
    static let refusal = 0.04

    /// How many counter-examples a term needs before the comparison replaces
    /// the floor.
    ///
    /// One. The three that stood here was measured on the floor path, before
    /// counter-examples existed; the comparison was never measured at a low
    /// count.
    static let counterMinimum = 1

    /// How far apart the two scores have to be before either side wins.
    ///
    /// A hedge, not a fix. Measured on the 20 held-out cases: it removes no
    /// error at any width up to 0.05, and every width above 0.01 starts turning
    /// correct decisions quiet — the two tightest correct margins are ±0.017.
    /// So 0.01 is the widest band that costs nothing.
    static let band = 0.01

    struct Summary: Codable, Equatable {
        let centre: [Float]
        let tightness: Double
        /// nil below `floorMinimum` uses, where there is nothing to leave out.
        let floor: Double?
        /// The sentences this was built from, so a portrait is recomputed when
        /// they change and not otherwise.
        let fingerprint: String
        let uses: Int
        /// The same two numbers over the term's counter-examples, or nil when
        /// it has fewer than `counterMinimum` of them.
        var counterCentre: [Float]?
        var counterTightness: Double?
        /// How many counters reached that centre. Zero when none was built,
        /// and short of the stored rows when the cut emptied one.
        var counters: Int
    }

    private var cache: [String: Summary] = [:]
    private var loadedFromDisk = false

    /// The build running for a term, and the uses it was started for. See
    /// `summary` for why an actor alone does not stop two of them.
    private var building: [String: (mark: String, task: Task<Summary, Error>)] = [:]

    /// Keyed by the model, because the numbers are only comparable within one
    /// set of weights. A model change invalidates every summary and no
    /// sentence.
    private static var cacheURL: URL {
        AppVariant.supportDirectory
            .appendingPathComponent("portraits-qwen3-embedding-0.6b-4bit.json")
    }

    // MARK: - the answer

    /// How typical this sentence is of the term, or nil if the term has no
    /// portrait yet.
    ///
    /// `span` is the word standing where the term would go — what was heard,
    /// not the term. It is left out of the vector, so what is measured is the
    /// sentence around it.
    func score(of span: String, in sentence: String, for term: String) async throws -> Double? {
        try await read(span, in: sentence, as: term)?.own
    }

    /// What the term's own sentences say about this one.
    enum Verdict {
        /// This is where the term lives.
        case authorises
        /// This is somewhere else entirely.
        case refuses
        /// Not far enough either way, or the term has no portrait.
        case nothing
    }

    /// One reading of one sentence, with the numbers behind it.
    ///
    /// The app and `--portrait` both go through this, so the bench scores the
    /// rule that ships and not a second copy of it.
    struct Reading {
        let verdict: Verdict
        /// Against the term's own sentences: cosine over tightness.
        let own: Double
        /// Against its counter-examples, the same way, or nil when it has too
        /// few for a centre.
        let against: Double?
        let floor: Double?
    }

    /// How this sentence reads, or nil if the term has no portrait yet.
    func read(_ span: String, in sentence: String, as term: String) async throws -> Reading? {
        guard let summary = try await summary(for: term) else { return nil }
        // The same cut the portrait was built with. Without it a sentence
        // holding both spellings scores its own term as context — the shape
        // that made the portrait grade its own write.
        let near = Self.context(
            of: span, in: sentence, cutting: Self.rivals(of: term, in: TermUses.load()[term] ?? [])
        ) ?? sentence
        let vector = try await WordVectors.shared.vector(.around, of: span, in: near)
        let own = WordVectors.cosine(vector, summary.centre) / summary.tightness

        guard let centre = summary.counterCentre, let tightness = summary.counterTightness,
              tightness > 0
        else {
            guard let floor = summary.floor else { return nil }
            let verdict: Verdict
            if own > floor {
                verdict = .authorises
            } else if own < floor - Self.refusal {
                verdict = .refuses
            } else {
                verdict = .nothing
            }
            return Reading(verdict: verdict, own: own, against: nil, floor: floor)
        }

        // Both sides divided by their own tightness. Mixing the scales was
        // measured at 14 right / 5 wrong / 1 quiet against 22 / 1 / 1.
        let against = WordVectors.cosine(vector, centre) / tightness
        let apart = own - against
        let verdict: Verdict
        if apart > Self.band {
            verdict = .authorises
        } else if apart < -Self.band {
            verdict = .refuses
        } else {
            verdict = .nothing
        }
        return Reading(verdict: verdict, own: own, against: against, floor: summary.floor)
    }

    func reads(_ span: String, in sentence: String, as term: String) async -> Verdict {
        do {
            guard let reading = try await read(span, in: sentence, as: term) else {
                return .nothing
            }
            if let against = reading.against {
                Log.write(String(
                    format: "portrait: %@ at \"%@\" is %.3f like its own sentences"
                        + " and %.3f like its counters — %@",
                    term, span, reading.own, against, "\(reading.verdict)"
                ))
            } else if let floor = reading.floor {
                Log.write(String(
                    format: "portrait: %@ at \"%@\" scores %.3f against a floor of %.3f — %@",
                    term, span, reading.own, floor, "\(reading.verdict)"
                ))
            }
            return reading.verdict
        } catch {
            Log.write("portrait: \(term) could not be scored (\(error.localizedDescription))")
            return .nothing
        }
    }

    // MARK: - a group of terms

    /// One member of a group at one place, and the numbers behind it.
    struct Standing {
        let term: String
        /// Nil when the term has no portrait at all, and then it never stands.
        let score: Double?
        let floor: Double?
        let uses: Int
        let stands: Bool
        /// No sentence at all. Not out — never seen. See
        /// `SoundGroup.Candidate.unknown`.
        var unknown: Bool { uses == 0 }
    }

    /// How a group of terms reads one place.
    struct GroupReading {
        let members: [Standing]
        /// Against the group's pooled counter rows, or nil when it has none.
        let plain: Double?
        /// How many counter rows reached that centre.
        let plainRows: Int
        let verdict: SoundGroup.Verdict
    }

    /// What every member of a group says about this sentence, and who wins.
    ///
    /// One vector, scored against every member's own centre and against the
    /// pooled counter rows. One vector and not one per member: the window is
    /// cut at every member's spelling and at every counter span *before* it is
    /// embedded, so the same reading of the sentence is what each portrait is
    /// asked about. Cutting per member would score them on different text.
    ///
    /// `span` is the word standing at the place — what was heard, not any
    /// member's spelling.
    func read(
        group members: [String], _ span: String, in sentence: String
    ) async throws -> GroupReading {
        let stored = TermUses.load()
        let rivals = Self.rivals(of: members, in: stored)
        let near = Self.context(of: span, in: sentence, cutting: rivals) ?? sentence
        let vector = try await WordVectors.shared.vector(.around, of: span, in: near)

        var standing: [Standing] = []
        var candidates: [SoundGroup.Candidate] = []
        for member in members {
            // A member with no sentence at all cannot be scored. That is the
            // ordinary state of the second name in a new group: it has never
            // been corrected, so nothing describes where it lives, and it
            // reaches the decision as unknown rather than being left out of
            // it.
            guard let held = try await centre(of: member, cutting: rivals, in: stored) else {
                let uses = stored[member]?.filter { !$0.counter }.count ?? 0
                standing.append(Standing(
                    term: member, score: nil, floor: nil, uses: uses, stands: false
                ))
                candidates.append(SoundGroup.Candidate(
                    name: member, score: nil, floor: nil, uses: uses
                ))
                continue
            }
            let score = WordVectors.cosine(vector, held.centre) / held.tightness
            let candidate = SoundGroup.Candidate(
                name: member, score: score, floor: held.floor, uses: held.uses
            )
            candidates.append(candidate)
            standing.append(Standing(
                term: member, score: score, floor: held.floor, uses: held.uses,
                stands: candidate.stands
            ))
        }

        var plain: Double?
        var plainRows = 0
        if let pooled = try await self.plain(of: members, cutting: rivals, in: stored) {
            plain = WordVectors.cosine(vector, pooled.centre) / pooled.tightness
            plainRows = pooled.rows
        }
        return GroupReading(
            members: standing, plain: plain, plainRows: plainRows,
            verdict: SoundGroup.decide(candidates, plain: plain, band: Self.band)
        )
    }

    /// The same, with every failure reading as "keep what was heard".
    ///
    /// The group path is the only thing deciding a group place, so an error
    /// here has to leave the transcript exactly as it arrived.
    func reads(
        group members: [String], _ span: String, in sentence: String
    ) async -> SoundGroup.Verdict {
        do {
            let reading = try await read(group: members, span, in: sentence)
            let said = reading.members.map { member in
                let score = member.score.map { String(format: "%.3f", $0) } ?? "—"
                let how = member.unknown ? " (unknown)" : (member.stands ? "" : " (out)")
                return "\(member.term) \(score)\(how)"
            }.joined(separator: ", ")
            let plain = reading.plain.map { String(format: "%.3f", $0) } ?? "—"
            Log.write("portrait: \"\(span)\" opens \(members.joined(separator: "/")) —"
                + " \(said), plain \(plain) — \(reading.verdict)")
            return reading.verdict
        } catch {
            Log.write("portrait: \(members.joined(separator: "/")) could not be scored"
                + " (\(error.localizedDescription))")
            return .keep
        }
    }

    /// One member's centre, from whatever sentences it has.
    ///
    /// Not `summary(for:)`. That one refuses a term with fewer than
    /// `floorMinimum` uses and no counter-example, because the single-term
    /// path has nothing to compare a score against and would write on a guess.
    /// A group member has the other members to lose to, so one sentence is
    /// enough to take part: with one use the centre is that sentence and the
    /// tightness is 1.
    ///
    /// The floor is still read off the term's own uses leaving one out, so it
    /// still needs three of them. Below that a member has no floor and cannot
    /// be out on one — it can only lose the comparison.
    ///
    /// Measured on the live app, 2026-09-10: `Eric` at two uses had no centre
    /// at all, so a two-member group asked nine times in a row and would have
    /// gone on asking until both names reached three.
    ///
    /// Cut with the *group's* rivals, the same cut the sentence gets, so every
    /// member is described by the same reading of its own sentences.
    private func centre(
        of member: String, cutting rivals: [String], in stored: [String: [TermUses.Use]]
    ) async throws -> (centre: [Float], tightness: Double, floor: Double?, uses: Int)? {
        let uses = (stored[member] ?? []).filter { !$0.counter }
        guard !uses.isEmpty else { return nil }
        let mark = Self.fingerprint(of: uses) + "\u{4}" + rivals.joined(separator: "\u{1}")
        if let held = memberCache[member], held.mark == mark { return held.built }

        var vectors: [[Float]] = []
        for use in uses {
            guard let near = Self.context(of: use.span, in: use.said, cutting: rivals) else {
                continue
            }
            vectors.append(try await WordVectors.shared.vector(.around, of: use.span, in: near))
        }
        guard !vectors.isEmpty else { return nil }
        let (middle, tightness) = Self.middle(of: vectors)
        guard tightness > 0 else { return nil }
        let built = (
            centre: middle, tightness: tightness, floor: Self.floor(of: vectors),
            uses: vectors.count
        )
        memberCache[member] = (mark: mark, built: built)
        return built
    }

    /// Held for the run only, like `plainCache`: a centre cut with one group's
    /// rivals means nothing to another group.
    ///
    /// One entry per member, and the mark it was built from sits in the value.
    /// Keyed by the mark instead, every correction left the centre it
    /// invalidated behind — 1024 floats each, for as long as the app runs.
    private var memberCache: [String: (
        mark: String,
        built: (centre: [Float], tightness: Double, floor: Double?, uses: Int)
    )] = [:]

    /// The group's plain centre: every member's counter rows, pooled.
    ///
    /// Plain is "an ordinary word that sounds like this" — Mick Jagger, the
    /// Versailles castle, a better stack than PHP. Nobody writes those down as
    /// a term, and each member's counter rows are exactly the sentences where
    /// one of them was put back to an ordinary word.
    ///
    /// Cached under the rows it was built from, the same way `summary` is: a
    /// row added anywhere in the group rebuilds it, and nothing else does.
    private func plain(
        of members: [String], cutting rivals: [String], in stored: [String: [TermUses.Use]]
    ) async throws -> (centre: [Float], tightness: Double, rows: Int)? {
        var rows: [TermUses.Use] = []
        for member in members { rows += (stored[member] ?? []).filter(\.counter) }
        guard rows.count >= Self.counterMinimum else { return nil }
        let group = members.sorted().joined(separator: "\u{1}")
        let mark = Self.fingerprint(of: rows) + "\u{4}" + rivals.joined(separator: "\u{1}")
        if let held = plainCache[group], held.mark == mark { return held.built }

        var vectors: [[Float]] = []
        for row in rows {
            guard let near = Self.context(of: row.span, in: row.said, cutting: rivals) else {
                continue
            }
            vectors.append(try await WordVectors.shared.vector(.around, of: row.span, in: near))
        }
        guard !vectors.isEmpty else { return nil }
        let (centre, tightness) = Self.middle(of: vectors)
        guard tightness > 0 else { return nil }
        let built = (centre: centre, tightness: tightness, rows: vectors.count)
        plainCache[group] = (mark: mark, built: built)
        return built
    }

    /// Held for the run only. A pooled centre is a few embeddings and it
    /// depends on rows from several terms, so it is not worth the cache file's
    /// invalidation rules.
    ///
    /// One entry per group, not per member: the centre is pooled over the
    /// whole group. The mark is in the value, so a row written anywhere in the
    /// group replaces the entry instead of adding one.
    private var plainCache: [String: (
        mark: String, built: (centre: [Float], tightness: Double, rows: Int)
    )] = [:]

    /// Every spelling that could stand at a group's place: each member's own
    /// rivals, pooled.
    static func rivals(of members: [String], in stored: [String: [TermUses.Use]]) -> [String] {
        var out: [String] = []
        for member in members {
            for word in rivals(of: member, in: stored[member] ?? []) {
                guard !out.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
                else { continue }
                out.append(word)
            }
        }
        return out
    }

    /// A term whose rows all but vanish under the cut. Thrown rather than
    /// built from what is left: `reads` turns it into "no opinion", which is
    /// what a term with no readable sentences should say.
    struct Thin: Error, LocalizedError {
        let term: String
        let left: Int
        var errorDescription: String? {
            "\(term) has \(left) sentence(s) left once the other spelling is cut"
        }
    }

    // MARK: - the other spelling

    /// Every spelling of this term that could stand in one of its sentences:
    /// the term itself, and the word at the site of each row it has. A
    /// counter's `span` is the ordinary word, so this set is exact — it is the
    /// spellings the user actually corrected, not words that look close.
    static func rivals(of term: String, in rows: [TermUses.Use]) -> [String] {
        var out = [term]
        func add(_ word: String?) {
            guard let word, !word.isEmpty,
                  !out.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
            else { return }
            out.append(word)
        }
        for row in rows {
            // The word at the site — a counter's is the ordinary word — and,
            // on a use, the spelling the correction replaced. The second is
            // what a term's first correction has, before any counter exists.
            add(row.span)
            add(row.heard)
        }
        return out
    }

    /// Every whole-word occurrence of `needle`, matched without case.
    ///
    /// Without case because a rival opening a sentence is capitalised there and
    /// not in the row that recorded it. Over-cutting costs a few words of
    /// context; under-cutting puts the other spelling back in the portrait.
    static func places(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        func letter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while let found = text.range(
            of: needle, options: [.caseInsensitive], range: from ..< text.endIndex
        ) {
            let before = found.lowerBound == text.startIndex
                || !letter(text[text.index(before: found.lowerBound)])
            let after = found.upperBound == text.endIndex || !letter(text[found.upperBound])
            if before && after { out.append(found) }
            guard found.lowerBound < text.endIndex else { break }
            from = text.index(after: found.lowerBound)
        }
        return out
    }

    /// `said` cut back so no other spelling of the term reaches the span.
    ///
    /// "I work with Jimmy and my friend is Jimmie." stores a use of `Jimmie`
    /// whose context holds a correct `Jimmy`, so the term's own portrait learns
    /// that `Jimmy` nearby is evidence for writing `Jimmie`. Measured on a
    /// seeded portrait against a clean row: the contaminated row moved two of
    /// four sentences, both toward writing the term, and cutting here put all
    /// four back where the clean row has them.
    ///
    /// `nil` when nothing but the span survives the cut. `WordVectors` averages
    /// every token except the span, so it would have nothing to average and
    /// would throw — inside the build loop, which costs the whole term its
    /// portrait rather than the one row.
    static func clipped(
        _ said: String, at span: Range<String.Index>, cutting rivals: [String]
    ) -> String? {
        var lower = said.startIndex, upper = said.endIndex
        for rival in rivals {
            for found in places(of: rival, in: said) where !found.overlaps(span) {
                if found.upperBound <= span.lowerBound { lower = max(lower, found.upperBound) }
                if found.lowerBound >= span.upperBound { upper = min(upper, found.lowerBound) }
            }
        }
        guard lower <= span.lowerBound, upper >= span.upperBound else { return nil }
        let before = said[lower ..< span.lowerBound], after = said[span.upperBound ..< upper]
        guard before.contains(where: \.isLetter) || after.contains(where: \.isLetter)
        else { return nil }
        return String(said[lower ..< upper])
    }

    /// The text a span should be read from: located in its sentence, then
    /// everything past another spelling of the term cut away. `nil` only when
    /// the cut leaves no sentence at all.
    static func context(of span: String, in said: String, cutting rivals: [String]) -> String? {
        guard let at = TermUses.occurrence(of: span, in: said) else { return said }
        return clipped(said, at: at, cutting: rivals)
    }

    // MARK: - building it

    func summary(for term: String) async throws -> Summary? {
        let all = TermUses.load()[term] ?? []
        // Counter-examples are sentences the term does *not* belong in. They
        // never enter the centre, the tightness or the floor: those describe
        // where the term lives, and a counter is the other place. They get a
        // centre of their own instead.
        let uses = all.filter { !$0.counter }
        let counters = all.filter(\.counter)
        guard uses.count >= Self.minimum else { return nil }
        // A term with no counter needs the floor, and the floor needs uses.
        guard counters.count >= Self.counterMinimum || uses.count >= Self.floorMinimum
        else { return nil }
        let mark = Self.fingerprint(of: all)

        if !loadedFromDisk { cache = Self.readCache(); loadedFromDisk = true }
        if let held = cache[term], held.fingerprint == mark { return held }

        // A build already running for this same fingerprint is the build this
        // caller wants, so join it rather than start a second one.
        //
        // Actor isolation is not enough on its own. `build` awaits a vector per
        // use, and an actor lets another call in at every one of those
        // suspensions — so two callers can both find the cache stale on either
        // side of the same await and both do the whole thing. That is exactly
        // the pair this stage now creates: the rebuild a correction starts, and
        // the dictation that names the term while it is still running. Without
        // this the dictation waits for a full build anyway, and the machine
        // does the work twice. Same shape as `Transcriber.loadingModels` and
        // `WordVectors.loading`.
        //
        // Keyed on the fingerprint too, because a build in flight for older
        // uses is the wrong answer for this caller — another correction may
        // have landed since it started.
        if let running = building[term], running.mark == mark {
            return try await running.task.value
        }

        let task = Task { try await Self.build(term: term, uses, against: counters, fingerprint: mark) }
        building[term] = (mark: mark, task: task)
        // Only if it is still ours. A correction arriving mid-build starts its
        // own task under this key, and clearing that one would let a third
        // caller start a duplicate of it.
        defer { if building[term]?.mark == mark { building[term] = nil } }

        let built = try await task.value
        cache[term] = built
        Self.writeCache(cache)
        return built
    }

    private static func build(
        term: String, _ uses: [TermUses.Use], against counters: [TermUses.Use],
        fingerprint mark: String
    ) async throws -> Summary {
        let rivals = rivals(of: term, in: uses + counters)
        var vectors: [[Float]] = []
        for use in uses {
            guard let near = context(of: use.span, in: use.said, cutting: rivals) else {
                Log.write("portrait: \(term) — \"\(use.said)\" is nothing but the term once"
                    + " the other spelling is cut, so it is not counted")
                continue
            }
            vectors.append(
                try await WordVectors.shared.vector(.around, of: use.span, in: near)
            )
        }
        guard vectors.count >= minimum else { throw Thin(term: term, left: vectors.count) }
        let (centre, tightness) = middle(of: vectors)

        // Built exactly as the positives are, from the ordinary word that
        // stands at the site rather than from the term.
        var counterCentre: [Float]?
        var counterTightness: Double?
        // What actually reached the centre. A counter the cut empties is
        // skipped below, so the stored count would overstate the portrait.
        var counterRows = 0
        if counters.count >= Self.counterMinimum {
            var against: [[Float]] = []
            for use in counters {
                guard let near = context(of: use.span, in: use.said, cutting: rivals) else {
                    Log.write("portrait: \(term) — a counter is nothing but the word once"
                        + " the other spelling is cut, so it is not counted")
                    continue
                }
                against.append(
                    try await WordVectors.shared.vector(.around, of: use.span, in: near)
                )
            }
            let (middleOf, spread) = middle(of: against)
            if spread > 0 {
                counterCentre = middleOf
                counterTightness = spread
                counterRows = against.count
            }
        }

        let floor = Self.floor(of: vectors)
        return Summary(
            centre: centre,
            tightness: tightness,
            floor: floor,
            fingerprint: mark,
            uses: vectors.count,
            counterCentre: counterCentre,
            counterTightness: counterTightness,
            counters: counterRows
        )
    }

    /// What a genuine use scores, each one measured against a portrait that
    /// does not contain it. Anything else compares a sentence with itself.
    ///
    /// Nil below `floorMinimum` vectors: there is nothing to leave out.
    private static func floor(of vectors: [[Float]]) -> Double? {
        guard vectors.count >= floorMinimum else { return nil }
        var selves: [Double] = []
        for index in vectors.indices {
            let rest = vectors.enumerated().filter { $0.offset != index }.map(\.element)
            guard rest.count > 1 else { continue }
            let (restCentre, restTightness) = middle(of: rest)
            guard restTightness > 0 else { continue }
            selves.append(cosine(vectors[index], restCentre) / restTightness)
        }
        guard !selves.isEmpty else { return nil }
        return quantileOf(selves, at: quantile)
    }

    /// The unit mean, and how close the members sit to it.
    private static func middle(of vectors: [[Float]]) -> ([Float], Double) {
        guard let width = vectors.first?.count, width > 0 else { return ([], 0) }
        var sum = [Double](repeating: 0, count: width)
        for vector in vectors where vector.count == width {
            for i in 0 ..< width { sum[i] += Double(vector[i]) }
        }
        let length = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return ([], 0) }
        let centre = sum.map { Float($0 / length) }
        let tightness = vectors.reduce(0.0) { $0 + cosine($1, centre) } / Double(vectors.count)
        return (centre, tightness)
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        WordVectors.cosine(a, b)
    }

    /// Linear interpolation between the two neighbouring values, which is what
    /// numpy does and what every measurement here was made with.
    private static func quantileOf(_ values: [Double], at fraction: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let share = position - Double(lower)
        return sorted[lower] * (1 - share) + sorted[upper] * share
    }

    private static func fingerprint(of uses: [TermUses.Use]) -> String {
        // The polarity is in the mark, so a counter added to a term rebuilds
        // its portrait even though it never enters one. The three minimums are
        // in it too: changing one changes what a stored summary means, and the
        // sentences it was built from do not move.
        let rule = "\(minimum)/\(counterMinimum)/\(floorMinimum)/cut1"
        let joined = uses
            .map { "\($0.counter ? "-" : "+")\($0.span)\u{1}\($0.said)\u{1}\($0.heard ?? "")" }
            .joined(separator: "\u{2}")
        let mark = rule + "\u{3}" + joined
        let digest = SHA256.hash(data: Data(mark.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - the cache

    /// An entry written by an older build is dropped, not kept.
    ///
    /// `Summary` has gained fields twice. Decoded as a whole dictionary, one
    /// old entry throws away every current one; kept as it is, a portrait would
    /// be read with a counter side it never had.
    private struct Entry: Decodable {
        let summary: Summary?
        init(from decoder: Decoder) throws { summary = try? Summary(from: decoder) }
    }

    private static func readCache() -> [String: Summary] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded.compactMapValues(\.summary)
    }

    private static func writeCache(_ summaries: [String: Summary]) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(summaries).write(to: cacheURL, options: .atomic)
        } catch {
            // The portrait is still in memory for this run, and the next run
            // rebuilds it. Not worth failing a correction over.
            Log.write("portrait: could not cache (\(error.localizedDescription))")
        }
    }
}
