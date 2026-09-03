import CoreML
import Foundation

/// What does ModernBERT put in a masked slot?
///
/// Put a `[MASK]` where a word is, and read the distribution over the whole
/// vocabulary at that one position. `SlotGate` and `SlotReference` read it to
/// decide whether the word a vocabulary term would replace belongs where it
/// stands.
///
/// It used to answer the sentence-boundary question too — a mask where the
/// period is, `log P(".") - log P(" <next word>")`, against a threshold. That
/// repaired 26% of the cuts. `SentenceJoin` chooses between whole readings of
/// the sentence now; see `SentenceReadings`.
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

    /// Words kept either side of the boundary, the next word counting as the
    /// first on the right. Wider does not fit in 64, and a word twelve away
    /// measured as noise rather than context.
    static let radius = 12

    /// The tokenizer alone, without the 300 MB model. `PARROTFLOW_TOKENIZER`
    /// points the check script at a copy.
    static var tokenizerURL: URL {
        if let path = ProcessInfo.processInfo.environment["PARROTFLOW_TOKENIZER"] {
            return URL(fileURLWithPath: path)
        }
        return SentenceModel.tokenizerURL
    }

    let tokenizer: BPETokenizer
    private let model: MLModel

    static func load(progress: (@Sendable (String) -> Void)? = nil) async throws -> SentenceProbe {
        let model = try await SentenceModel.shared.prepare(progress: progress)
        // The tokenizer runs `assertBoundaryIDs` as it parses, so one that
        // would score the wrong ids throws here rather than answering.
        let tokenizer = try await SentenceModel.shared.tokenizer(at: tokenizerURL)
        return SentenceProbe(tokenizer: tokenizer, model: model)
    }

    // MARK: - One forward pass

    /// `left` ends on a word with no trailing space and `right` carries its own
    /// leading space: the mask stands for the token including that space.
    func at(left: String, right: String) throws -> Slot {
        var head = tokenizer.encode(left)
        var tail = tokenizer.encode(right)
        // ±12 words fits every window measured. This is the guard for the one
        // nobody measured: a long run of rare words, or a caller that did not
        // window. Drop from the far ends, never from the mask.
        while head.count + tail.count > Self.length - 3 {
            if head.count >= tail.count { head.removeFirst() } else { tail.removeLast() }
        }

        let maskAt = 1 + head.count
        var ids = [tokenizer.cls] + head + [tokenizer.mask] + tail + [tokenizer.sep]
        ids += Array(repeating: tokenizer.pad, count: Self.length - ids.count)

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        for (index, id) in ids.enumerated() { input[index] = NSNumber(value: id) }

        // `attention_mask` is not an input. The conversion builds it as
        // ones_like(input_ids), so the padding is attended and the reference
        // has to pad the same way to get the same number.
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["input_ids": input])
        )
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw Failure.shape("the model returned no logits")
        }
        return try Slot(logits: logits, at: maskAt, tokenizer: tokenizer)
    }

    /// The distribution at one position, as log-probabilities.
    struct Slot {
        private let logits: [Float]
        private let logSumExp: Double
        private let tokenizer: BPETokenizer

        let position: Int

        init(logits array: MLMultiArray, at position: Int, tokenizer: BPETokenizer) throws {
            let width = tokenizer.count
            guard array.count >= (position + 1) * width else {
                throw Failure.shape("logits are \(array.count) values, too few for row \(position)")
            }
            guard array.strides.map(\.intValue).last == 1,
                  array.strides.dropLast().last?.intValue == width else {
                throw Failure.shape("logits are strided \(array.strides), not contiguous rows")
            }
            // One row, read in place. Going through `MLShapedArray<Float>`
            // first is correct and costs 440 ms of the 450 a call took: it
            // walks all 64 x 50368 values to reach the one row this needs.
            let row = position * width
            switch array.dataType {
            case .float32:
                self.logits = array.withUnsafeBufferPointer(ofType: Float.self) {
                    Array($0[row..<(row + width)])
                }
            case .float16:
                // `Float16` conforms to `MLShapedArrayScalar` only from macOS 15,
                // and this type ships to macOS 14.
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

        func logProbability(of id: Int) -> Double {
            guard logits.indices.contains(id) else { return -.infinity }
            return Double(logits[id]) - logSumExp
        }

        /// The `k` most likely tokens, with their leading space kept.
        func top(_ k: Int) -> [Prediction] {
            logits.indices.sorted { logits[$0] > logits[$1] }.lazy
                .compactMap { id in
                    self.tokenizer.word(of: id).map {
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
