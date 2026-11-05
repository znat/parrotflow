import Foundation

/// What a `returns: json` transform that declares `readings: true` gets as `readings`.
struct ReadingsField: Encodable, Sendable {
    struct Boundary: Encodable, Sendable {
        /// Character offset of the mark in the envelope's `text`.
        let at: Int
        let mark: String
        /// Character offset of the capital after it.
        let wordAt: Int
        /// Per-token mean log-probability of each reading, by `SentenceReadings` key.
        let means: [String: Double]
        let winner: String

        enum CodingKeys: String, CodingKey { case at, mark, wordAt = "word_at", means, winner }
    }

    let language: String
    let boundaries: [Boundary]
    /// Why there are no readings when there should be some.
    let missing: String?

    /// Every boundary where a sentence mark is followed by a capital, read
    /// after the doubled-stop collapse, one padded batch per boundary.
    ///
    /// Never loads the model.
    @available(macOS 14, *)
    static func of(_ text: String, language: String, config: Config, stage: String) async -> ReadingsField {
        func missing(_ reason: String) -> ReadingsField {
            Log.write("pipeline: \(stage) runs without the sentence readings — \(reason)")
            return ReadingsField(language: language, boundaries: [], missing: reason)
        }
        guard SentenceJoin.languages.contains(language) else {
            return missing("they are read in English and French only")
        }
        let (collapsed, from) = Pipeline.collapsingDoubledStopMapped(text)
        let marks = config.transcription.marks(for: language)
        let found = SentenceJoin.boundaries(
            in: collapsed, scanning: SentenceJoin.scanned(marks), refusing: config.abbreviations
        ).filter { collapsed[$0.next.lowerBound].isUppercase }
        guard !found.isEmpty else {
            return ReadingsField(language: language, boundaries: [], missing: nil)
        }
        guard await SentenceReadings.shared.isLoaded else {
            return missing("the sentence model is not in memory yet")
        }
        var out: [Boundary] = []
        for boundary in found {
            let mark = String(boundary.mark)
            let scores: [SentenceReadings.Score]
            do {
                scores = try await SentenceReadings.shared.read(
                    left: String(collapsed[..<boundary.at]),
                    right: String(collapsed[boundary.next.lowerBound...]),
                    found: mark, marks: marks
                )
            } catch {
                return missing(error.localizedDescription)
            }
            guard let best = SentenceJoin.winner(of: scores),
                  scores.allSatisfy({ $0.mean.isFinite }) else {
                return missing("a reading that is not a number")
            }
            out.append(Boundary(
                at: from[collapsed.distance(from: collapsed.startIndex, to: boundary.at)],
                mark: mark,
                wordAt: from[collapsed.distance(from: collapsed.startIndex, to: boundary.next.lowerBound)],
                means: Dictionary(scores.map { ($0.key, $0.mean) }) { first, _ in first },
                winner: best.key
            ))
        }
        return ReadingsField(language: language, boundaries: out, missing: nil)
    }
}
