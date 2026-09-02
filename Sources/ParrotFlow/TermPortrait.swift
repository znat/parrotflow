import CryptoKit
import Foundation

/// What a term's confirmed sentences say about where it belongs.
///
/// Three numbers per term, computed from the sentences `TermUses` keeps:
///
///   - `centre`, the mean of the context vectors — every token of a sentence
///     except the term's own, so it describes the sentence and not the word;
///   - `tightness`, how close those sentences sit to that centre;
///   - `floor`, what a genuine use of this term scores against it.
///
/// A new sentence is scored against the centre and divided by the tightness.
/// Above the floor, the rewrite is authorised.
///
/// A term that has been corrected out of enough sentences gets a second centre
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

    /// Fewer than this and the numbers mean nothing: at two uses the floor came
    /// out below every ordinary word, at three it holds. Under it, a term has
    /// no portrait and the stage decides as it does today.
    static let minimum = 3

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
    /// `SentenceProbe.radius` is 12 for the other test, which reads a mask and
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
    /// Below this the counter centre is untestable, and the one term measured
    /// with two counters got both of its own cases wrong. 3 costs nothing on
    /// either bench set and is `minimum` again, so there is one number here and
    /// not two.
    static let counterMinimum = 3

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
        let floor: Double
        /// The sentences this was built from, so a portrait is recomputed when
        /// they change and not otherwise.
        let fingerprint: String
        let uses: Int
        /// The same two numbers over the term's counter-examples, or nil when
        /// it has fewer than `counterMinimum` of them.
        var counterCentre: [Float]?
        var counterTightness: Double?
        /// Counted whether or not there were enough to build a centre.
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
        let floor: Double
    }

    /// How this sentence reads, or nil if the term has no portrait yet.
    func read(_ span: String, in sentence: String, as term: String) async throws -> Reading? {
        guard let summary = try await summary(for: term) else { return nil }
        let vector = try await WordVectors.shared.vector(.around, of: span, in: sentence)
        let own = WordVectors.cosine(vector, summary.centre) / summary.tightness

        guard let centre = summary.counterCentre, let tightness = summary.counterTightness,
              tightness > 0
        else {
            let verdict: Verdict
            if own > summary.floor {
                verdict = .authorises
            } else if own < summary.floor - Self.refusal {
                verdict = .refuses
            } else {
                verdict = .nothing
            }
            return Reading(verdict: verdict, own: own, against: nil, floor: summary.floor)
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
            } else {
                Log.write(String(
                    format: "portrait: %@ at \"%@\" scores %.3f against a floor of %.3f — %@",
                    term, span, reading.own, reading.floor, "\(reading.verdict)"
                ))
            }
            return reading.verdict
        } catch {
            Log.write("portrait: \(term) could not be scored (\(error.localizedDescription))")
            return .nothing
        }
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

        let task = Task { try await Self.build(uses, against: counters, fingerprint: mark) }
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
        _ uses: [TermUses.Use], against counters: [TermUses.Use], fingerprint mark: String
    ) async throws -> Summary {
        var vectors: [[Float]] = []
        for use in uses {
            vectors.append(
                try await WordVectors.shared.vector(.around, of: use.span, in: use.said)
            )
        }
        let (centre, tightness) = middle(of: vectors)

        // Built exactly as the positives are, from the ordinary word that
        // stands at the site rather than from the term.
        var counterCentre: [Float]?
        var counterTightness: Double?
        if counters.count >= Self.counterMinimum {
            var against: [[Float]] = []
            for use in counters {
                against.append(
                    try await WordVectors.shared.vector(.around, of: use.span, in: use.said)
                )
            }
            let (middleOf, spread) = middle(of: against)
            if spread > 0 {
                counterCentre = middleOf
                counterTightness = spread
            }
        }

        // What a genuine use scores, each one measured against a portrait that
        // does not contain it. Anything else compares a sentence with itself.
        var selves: [Double] = []
        for index in vectors.indices {
            let rest = vectors.enumerated().filter { $0.offset != index }.map(\.element)
            guard rest.count > 1 else { continue }
            let (restCentre, restTightness) = middle(of: rest)
            guard restTightness > 0 else { continue }
            selves.append(cosine(vectors[index], restCentre) / restTightness)
        }
        return Summary(
            centre: centre,
            tightness: tightness,
            floor: quantileOf(selves, at: quantile),
            fingerprint: mark,
            uses: uses.count,
            counterCentre: counterCentre,
            counterTightness: counterTightness,
            counters: counters.count
        )
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
        // its portrait even though it never enters one.
        let joined = uses
            .map { "\($0.counter ? "-" : "+")\($0.span)\u{1}\($0.said)" }
            .joined(separator: "\u{2}")
        let digest = SHA256.hash(data: Data(joined.utf8))
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
