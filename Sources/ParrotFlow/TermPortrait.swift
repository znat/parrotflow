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
/// This half only ever authorises. `SlotReference` is the half that refuses, and
/// when the two disagree neither wins — the reading is offered instead.
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

    struct Summary: Codable, Equatable {
        let centre: [Float]
        let tightness: Double
        let floor: Double
        /// The sentences this was built from, so a portrait is recomputed when
        /// they change and not otherwise.
        let fingerprint: String
        let uses: Int
    }

    private var cache: [String: Summary] = [:]
    private var loadedFromDisk = false

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
        guard let summary = try await summary(for: term) else { return nil }
        let vector = try await WordVectors.shared.vector(.around, of: span, in: sentence)
        return WordVectors.cosine(vector, summary.centre) / summary.tightness
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

    func reads(_ span: String, in sentence: String, as term: String) async -> Verdict {
        do {
            guard let summary = try await summary(for: term),
                  let score = try await score(of: span, in: sentence, for: term)
            else { return .nothing }
            let verdict: Verdict
            if score > summary.floor {
                verdict = .authorises
            } else if score < summary.floor - Self.refusal {
                verdict = .refuses
            } else {
                verdict = .nothing
            }
            Log.write(String(
                format: "portrait: %@ at \"%@\" scores %.3f against a floor of %.3f — %@",
                term, span, score, summary.floor, "\(verdict)"
            ))
            return verdict
        } catch {
            Log.write("portrait: \(term) could not be scored (\(error.localizedDescription))")
            return .nothing
        }
    }

    // MARK: - building it

    func summary(for term: String) async throws -> Summary? {
        let all = TermUses.load()[term] ?? []
        // Counter-examples are sentences the term does *not* belong in. They
        // are fingerprinted, so adding one rebuilds, but they never enter the
        // centre, the tightness or the floor: those describe where the term
        // lives, and a counter is the other place.
        let uses = all.filter { !$0.counter }
        guard uses.count >= Self.minimum else { return nil }
        let mark = Self.fingerprint(of: all)

        if !loadedFromDisk { cache = Self.readCache(); loadedFromDisk = true }
        if let held = cache[term], held.fingerprint == mark { return held }

        let built = try await Self.build(uses, fingerprint: mark)
        cache[term] = built
        Self.writeCache(cache)
        return built
    }

    private static func build(
        _ uses: [TermUses.Use], fingerprint mark: String
    ) async throws -> Summary {
        var vectors: [[Float]] = []
        for use in uses {
            vectors.append(
                try await WordVectors.shared.vector(.around, of: use.span, in: use.said)
            )
        }
        let (centre, tightness) = middle(of: vectors)

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
            uses: uses.count
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

    private static func readCache() -> [String: Summary] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Summary].self, from: data)
        else { return [:] }
        return decoded
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
