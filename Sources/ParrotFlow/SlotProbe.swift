import CoreML
import Foundation
@preconcurrency import Tokenizers

/// What word does this position expect? One masked forward pass over
/// mmBERT-small.
///
/// `SlotReference` reads the answer as a set of ten words to measure two
/// readings against. `SlotGate` reads it as a part of speech. Neither needs a
/// probability, so this returns words and stops there.
///
/// The boundary stage is not this probe with another model. mmBERT does not
/// know where an English sentence ends, so that stage reads Qwen through
/// `SentenceReadings` instead.
@available(macOS 14, *)
struct SlotProbe {

    enum Failure: LocalizedError {
        case shape(String)

        var errorDescription: String? {
            switch self {
            case .shape(let what): return "slot probe: \(what)"
            }
        }
    }

    /// The length the model is traced at. Fixed, so every call pads to it.
    static let length = 64

    /// Words kept either side of the slot. Wider does not fit in 64, and a word
    /// twelve away measured as noise rather than context.
    static let radius = 12

    let tokenizer: SlotTokenizer
    private let model: MLModel

    static func load(progress: (@Sendable (String) -> Void)? = nil) async throws -> SlotProbe {
        let model = try await SlotModel.shared.prepare(progress: progress)
        let tokenizer = try await SlotModel.shared.tokenizer(at: SlotModel.tokenizerDirectory)
        return SlotProbe(tokenizer: tokenizer, model: model)
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
        var ids = [tokenizer.bos] + head + [tokenizer.mask] + tail + [tokenizer.eos]
        let real = ids.count
        ids += Array(repeating: tokenizer.pad, count: Self.length - ids.count)

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        let attention = try MLMultiArray(
            shape: [1, NSNumber(value: Self.length)], dataType: .int32
        )
        for (index, id) in ids.enumerated() {
            input[index] = NSNumber(value: id)
            attention[index] = NSNumber(value: index < real ? 1 : 0)
        }

        // `attention_mask` is a real input, and it has to be. Built as
        // ones_like(input_ids) inside the graph — the shape the earlier
        // ModernBERT conversion used — the padding is read as text, and this
        // model minds:
        // on the 238-case bench it costs 12 decisions and 0.046 of AUC, and no
        // filler list of the 238 survives it.
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(
                dictionary: ["input_ids": input, "attention_mask": attention]
            )
        )
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw Failure.shape("the model returned no logits")
        }
        return try Slot(logits: logits, at: maskAt, tokenizer: tokenizer)
    }

    /// The distribution at one position, as the words it ranks highest.
    struct Slot {
        private let logits: [Float]
        private let tokenizer: SlotTokenizer

        let position: Int

        init(logits array: MLMultiArray, at position: Int, tokenizer: SlotTokenizer) throws {
            // The width is the vocabulary, read from the tensor rather than
            // from the tokenizer: the two agree, and only one of them describes
            // the array being indexed.
            guard let width = array.shape.last?.intValue, width > 0 else {
                throw Failure.shape("logits have no width")
            }
            guard array.count >= (position + 1) * width else {
                throw Failure.shape("logits are \(array.count) values, too few for row \(position)")
            }
            guard array.strides.map(\.intValue).last == 1,
                  array.strides.dropLast().last?.intValue == width else {
                throw Failure.shape("logits are strided \(array.strides), not contiguous rows")
            }
            // One row, read in place. Going through `MLShapedArray<Float>`
            // first walks all 64 x 256000 values to reach the one row this
            // needs, which is most of the call.
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
        }

        /// The `k` most likely tokens, as words, with their leading space kept.
        ///
        /// A bounded scan rather than a sort. The vocabulary is 256,000 wide
        /// and the callers want ten of it or sixty.
        func top(_ k: Int) -> [String] {
            guard k > 0 else { return [] }
            var best: [(id: Int, value: Float)] = []
            best.reserveCapacity(k + 1)
            var cutoff = -Float.greatestFiniteMagnitude
            for (id, value) in logits.enumerated() {
                if best.count == k, value <= cutoff { continue }
                var at = best.count
                while at > 0, best[at - 1].value < value { at -= 1 }
                best.insert((id, value), at: at)
                if best.count > k { best.removeLast() }
                if best.count == k { cutoff = best[k - 1].value }
            }
            return best.compactMap { tokenizer.word(of: $0.id) }
        }
    }
}

/// mmBERT-small's tokenizer, through `swift-transformers`.
///
/// mmBERT's file is Gemma-shaped — byte-fallback BPE, a `Metaspace`
/// pre-tokenizer that writes a space as `▁`, and `<bos> <eos> <mask> <pad>` for
/// special tokens. `AutoTokenizer` already reads all of that, and
/// `WordVectors` already depends on it.
///
/// `scripts/check-slot-tokenizer.sh` compares it against the reference
/// tokenizer, id by id, on `tests/slot-tokenizer-cases.json`.
///
/// `@unchecked Sendable` because `Tokenizers.Tokenizer` is not Sendable and is
/// read-only after loading. `WordVectors` wraps the same protocol the same way.
struct SlotTokenizer: @unchecked Sendable {

    enum Failure: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): return "tokenizer.json: no \(name)"
            }
        }
    }

    let bos: Int
    let eos: Int
    let mask: Int
    let pad: Int

    private let upstream: any Tokenizers.Tokenizer

    static func load(from directory: URL) async throws -> SlotTokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        func id(_ name: String) throws -> Int {
            guard let id = upstream.convertTokenToId(name), upstream.convertIdToToken(id) == name
            else { throw Failure.missing(name) }
            return id
        }
        return SlotTokenizer(
            bos: try id("<bos>"), eos: try id("<eos>"),
            mask: try id("<mask>"), pad: try id("<pad>"), upstream: upstream
        )
    }

    /// The ids of `text`, with no special tokens.
    ///
    /// An empty string encodes to nothing. The `Metaspace` pre-tokenizer would
    /// otherwise prepend its `▁` and hand back one token for no text, and a
    /// word at the start of a sentence arrives here with an empty left side.
    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        return upstream.encode(text: text, addSpecialTokens: false)
    }

    /// The word a token stands for, its word-start marker read back as a space.
    ///
    /// `▁` is how this tokenizer writes a space, so `▁castle` is " castle" and
    /// `castle` is a continuation of the word before it. Callers trim, so both
    /// arrive as `castle`; keeping the space is what lets one that cares tell
    /// them apart.
    func word(of id: Int) -> String? {
        upstream.convertIdToToken(id).map {
            $0.replacingOccurrences(of: "\u{2581}", with: " ")
        }
    }
}
