import CoreML
import Foundation

/// What ModernBERT thinks belongs in one slot of a sentence.
///
/// Put a `[MASK]` between two pieces of text and read the distribution at it.
/// That answers two different questions with the same forward pass: how likely
/// one named token is there, and which words the model would put there.
///
///     let probe = try await SentenceProbe.load()
///     let slot = try probe.at(left: "we have to do it", right: " works well")
///     slot.logProbability(of: id)     // "is there a period, or does it run on"
///     slot.top(10)                    // "what word would go here"
///
/// One `at` call is one forward pass, about 8 ms. Nothing here batches, and
/// that is on purpose: a caller ranking the windows of a sentence pays that
/// per window and should be able to see it in its own code.
///
/// **The mask stands for the token including its leading space.** In
/// `"The capital of Ireland is[MASK]."` the answer is `" Dublin"`, not
/// `"Dublin"` — different ids, and only the first is right. So `left` ends on
/// a word with no trailing space, and `right` carries its own leading space
/// when the next thing is a word. See `BPETokenizer`.
@available(macOS 14, *)
struct SentenceProbe {

    enum Failure: LocalizedError {
        case shape(String)

        var errorDescription: String? {
            switch self {
            case .shape(let what): return "sentence probe: \(what)"
            }
        }
    }

    /// The only length this conversion is faithful at. Correlation against
    /// PyTorch at the mask is 0.9964-1.0000 here and 0.8996-0.9862 at 128.
    static let length = 64

    /// Words kept either side of the site. Measured over 200 periods and 120
    /// cuts: ±12 fits inside 64 every time and reads better than the whole
    /// sentence, because a word twelve away is noise rather than context.
    static let radius = 12

    let tokenizer: BPETokenizer
    private let model: MLModel

    /// Downloads the model if it is not there, then loads it and the tokenizer.
    /// Both are cached on `SentenceModel.shared`, so calling this again is cheap.
    static func load(progress: (@Sendable (String) -> Void)? = nil) async throws -> SentenceProbe {
        let model = try await SentenceModel.shared.prepare(progress: progress)
        return SentenceProbe(
            tokenizer: try await SentenceModel.shared.loadTokenizer(), model: model
        )
    }

    // MARK: - One slot

    /// One forward pass, with the mask between `left` and `right`.
    ///
    /// Both sides are trimmed to `radius` words first, from the end away from
    /// the mask, so the text touching the mask is passed through unchanged —
    /// a trim that rebuilt the string would eat the leading space `right`
    /// needs.
    func at(left: String, right: String) throws -> Slot {
        var head = tokenizer.encode(Self.trim(left, keeping: .end))
        var tail = tokenizer.encode(Self.trim(right, keeping: .start))

        // ±12 words fits in every window measured, so this is the guard for
        // the window nobody measured: a long word run, or a caller that did
        // not window at all. Drop from the far ends, never from the mask.
        let budget = Self.length - 3
        while head.count + tail.count > budget {
            if head.count >= tail.count { head.removeFirst() } else { tail.removeLast() }
        }

        let maskAt = 1 + head.count
        var ids = [tokenizer.cls] + head + [tokenizer.mask] + tail + [tokenizer.sep]
        ids += Array(repeating: tokenizer.pad, count: max(0, Self.length - ids.count))

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        for (index, id) in ids.enumerated() { input[index] = NSNumber(value: id) }

        // `attention_mask` is not an input. The conversion wrapper builds it as
        // ones_like(input_ids), so the padding is attended. Measured to cost
        // nothing on this task; that is a property of this task, not a promise.
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["input_ids": input])
        )
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw Failure.shape("the model returned no logits")
        }
        return try Slot(logits: logits, at: maskAt, tokenizer: tokenizer)
    }

    // MARK: - The window

    private enum Keeping { case start, end }

    /// The `radius` words at one end, cut at a space so the other end — the
    /// one the mask touches — comes through byte for byte.
    private static func trim(_ text: String, keeping end: Keeping) -> String {
        let spaces = text.indices.filter { text[$0] == " " }
        switch end {
        case .end:
            guard spaces.count >= radius else { return text }
            return String(text[text.index(after: spaces[spaces.count - radius])...])
        case .start:
            // A leading space is the mask's own, not a word separator, so it
            // is not one of the cuts counted here.
            let cuts = text.hasPrefix(" ") ? Array(spaces.dropFirst()) : spaces
            guard cuts.count >= radius else { return text }
            return String(text[..<cuts[radius - 1]])
        }
    }

    // MARK: - What came back

    /// The distribution at one position, as log-probabilities.
    struct Slot {
        private let logits: [Float]
        private let logSumExp: Double
        private let tokenizer: BPETokenizer

        /// Where the mask ended up, for a caller reporting what it asked.
        let position: Int

        init(logits array: MLMultiArray, at position: Int, tokenizer: BPETokenizer) throws {
            let width = tokenizer.count
            guard array.count >= (position + 1) * width else {
                throw Failure.shape("logits are \(array.count) values, too few for row \(position)")
            }
            // Reading a row in place needs the rows laid out end to end.
            guard array.strides.map(\.intValue).last == 1,
                  array.strides.dropLast().last?.intValue == width else {
                throw Failure.shape("logits are strided \(array.strides), not contiguous rows")
            }
            // One row, read in place. Converting the whole array to
            // `MLShapedArray<Float>` first is correct and costs 440 ms of the
            // 450 a call took: it walks all 64 x 50368 values to reach the one
            // row this needs.
            let row = position * width
            switch array.dataType {
            case .float32:
                self.logits = array.withUnsafeBufferPointer(ofType: Float.self) {
                    Array($0[row..<(row + width)])
                }
            case .float16:
                // `Float16` conforms to `MLShapedArrayScalar` only from macOS 15.
                guard #available(macOS 15, *) else {
                    throw Failure.shape("float16 logits need macOS 15")
                }
                self.logits = array.withUnsafeBufferPointer(ofType: Float16.self) {
                    $0[row..<(row + width)].map { Float($0) }
                }
            case .double:
                self.logits = array.withUnsafeBufferPointer(ofType: Double.self) {
                    $0[row..<(row + width)].map { Float($0) }
                }
            default:
                throw Failure.shape("logits are \(array.dataType), which is not a float")
            }
            self.position = position
            self.tokenizer = tokenizer

            let top = Double(self.logits.max() ?? 0)
            self.logSumExp = top + log(self.logits.reduce(0.0) { $0 + exp(Double($1) - top) })
        }

        /// How likely that exact token is here. `-.infinity` for an id outside
        /// the vocabulary.
        ///
        /// Take the id from `BPETokenizer.firstID(of:)` and write the leading
        /// space: `" That"`, not `"That"`.
        func logProbability(of id: Int) -> Double {
            guard logits.indices.contains(id) else { return -.infinity }
            return Double(logits[id]) - logSumExp
        }

        /// The `k` most likely tokens, as text a caller can put back into the
        /// sentence. The leading space is kept.
        func top(_ k: Int) -> [Prediction] {
            let ranked = logits.indices.sorted { logits[$0] > logits[$1] }
            return ranked.lazy
                .compactMap { id in
                    tokenizer.word(of: id).map {
                        Prediction(word: $0, logProbability: self.logProbability(of: id))
                    }
                }
                .prefix(k)
                .map { $0 }
        }
    }

    struct Prediction {
        let word: String
        let logProbability: Double
    }
}
