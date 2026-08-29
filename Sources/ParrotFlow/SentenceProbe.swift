import CoreML
import Foundation

/// Is this period real, or did a pause cut one sentence in two?
///
/// Put a `[MASK]` where the period is, lowercase the word after it, and ask
/// ModernBERT what belongs in the slot:
///
///     score = log P(".") - log P(" <next word>")
///
/// One forward pass reads both. Below the threshold, the period is false and
/// the two halves are one sentence. Measured over 194 real periods and 130
/// synthetic cuts of this user's own dictation:
///
///     -4    32% of cuts repaired    0.0 false joins per 100 real periods
///     -2    55%                     1.2
///      0    82%                     6.1
///
/// Nothing in the app calls this yet.
@available(macOS 14, *)
struct SentenceProbe {

    enum Failure: LocalizedError {
        case shape(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .shape(let what): return "sentence probe: \(what)"
            case .empty: return "sentence probe: no word after the boundary"
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
    private let period: Int

    static func load(progress: (@Sendable (String) -> Void)? = nil) async throws -> SentenceProbe {
        let model = try await SentenceModel.shared.prepare(progress: progress)
        // `load` runs `assertBoundaryIDs`, so a tokenizer that would score the
        // wrong ids throws here rather than answering.
        let tokenizer = try BPETokenizer.load(contentsOf: tokenizerURL)
        guard let period = tokenizer.firstID(of: ".") else {
            throw Failure.shape("\".\" does not encode")
        }
        return SentenceProbe(tokenizer: tokenizer, model: model, period: period)
    }

    // MARK: - One boundary

    struct Reading {
        /// `log P(".") - log P(" <next word>")`. Below the threshold, the
        /// period is false.
        let score: Double
        let periodLogProbability: Double
        let nextLogProbability: Double
        /// The next word with its leading space, as the model reads it.
        let next: String
        let top: [Prediction]
        /// The masked text the model was given, for a caller checking its work.
        let text: String
    }

    func read(left: String, right: String) throws -> Reading {
        // The period under test is dropped before the words are counted, so a
        // caller that kept it and one that did not get the same window.
        let kept = String(left.reversed().drop { $0 == "." }.reversed())
        let before = kept.split(whereSeparator: \.isWhitespace).suffix(Self.radius).map(String.init)
        let tail = right.split(whereSeparator: \.isWhitespace).map(String.init)
        guard var next = tail.first else { throw Failure.empty }
        next = next.prefix(1).lowercased() + next.dropFirst()
        let after = ([next] + tail.dropFirst()).prefix(Self.radius).joined(separator: " ")

        guard let nextID = tokenizer.firstID(of: " " + next) else {
            throw Failure.shape("\((" " + next).debugDescription) does not encode")
        }
        let slot = try at(left: before.joined(separator: " "), right: " " + after)
        let periodLogProbability = slot.logProbability(of: period)
        let nextLogProbability = slot.logProbability(of: nextID)
        return Reading(
            score: periodLogProbability - nextLogProbability,
            periodLogProbability: periodLogProbability,
            nextLogProbability: nextLogProbability,
            next: " " + next,
            top: slot.top(5),
            text: before.joined(separator: " ") + " [MASK] " + after
        )
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
