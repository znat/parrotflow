import Foundation
import MLX
import MLXLLM
import MLXLMCommon
@preconcurrency import Tokenizers

/// Qwen3-Embedding's per-token states, which is what the vocabulary stage
/// compares.
///
/// Two vectors come out of the same forward pass. The **word** vector is the
/// mean of the sub-token states of one word where it sits in the sentence. The
/// **context** vector is the mean of every other token. A vocabulary term is
/// unknown to the tokenizer by construction, so it has no static embedding of
/// its own; these are the only vectors it has.
///
/// Ollama cannot serve this. Its embed endpoint returns one pooled vector per
/// text, and pooling loses the signal: on eight real proposals, 6 of 8 decided
/// correctly from a word's own sub-token states, 4 of 8 from a one-word window,
/// 2 of 8 from one vector per sentence.
///
/// Qwen and not ModernBERT. Eight models were scored on the same 59
/// proposals; Qwen is the only one that never wrote a name over an ordinary
/// word, at any threshold. ModernBERT's own vectors veto half the correct
/// writes. 4-bit keeps the property and is 4.6x faster than fp32.
@available(macOS 14, *)
actor WordVectors {

    static let shared = WordVectors()

    /// The cache and its download. The file list is not the whole repository:
    /// `model.safetensors.index.json` is absent from it, and listing a file
    /// that is not there fails the fetch on `unlisted`.
    static let cache = MLXModelCache(
        repository: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        files: [
            "config.json",
            "model.safetensors",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "vocab.json",
            "merges.txt",
        ],
        directory: AppVariant.supportDirectory
            .appendingPathComponent("models/qwen3-embedding-0.6b-4bit", isDirectory: true),
        lockURL: AppVariant.supportDirectory
            .appendingPathComponent("models/qwen3-embedding.lock"),
        label: "word vectors"
    )

    static var directory: URL { cache.directory }

    enum Failure: LocalizedError {
        case notQwen(String)
        case spanNotFound(word: String, in: String)

        var errorDescription: String? {
            switch self {
            case .notQwen(let kind):
                return "the word-vector model loaded as \(kind), not Qwen3"
            case .spanNotFound(let word, let sentence):
                return "\"\(word)\" has no clean token span in \"\(sentence)\""
            }
        }
    }

    static var isCached: Bool { cache.isCached }

    private var loaded: ModelContext?

    /// The fetch in flight, if any. Actor isolation stops a torn read of
    /// `loaded`, not two callers both finding it nil across the same `await`.
    private var loading: Task<ModelContext, Error>?

    /// True once the weights are in memory.
    ///
    /// The gate asks before it runs. A dictation must never wait on a 400 MB
    /// download and an MLX warm-up: the first one cost about twenty seconds
    /// with the pill on screen, which reads as the app having hung.
    var isLoaded: Bool { loaded != nil }

    /// Starts the load if nothing is doing it, and returns at once.
    func warm() {
        guard loaded == nil, loading == nil else { return }
        Task { [weak self] in
            do { try await self?.prepare() } catch {
                Log.write("word vectors: \(error.localizedDescription);"
                    + " the sentence gate stands aside until they load")
            }
        }
    }

    /// Downloads and loads, or does nothing if it is already loaded.
    ///
    /// `progress` gets a label shaped like "word vectors 43%", already
    /// de-duplicated. `ModelContext` is not `Sendable`, so it never leaves this
    /// actor — callers get vectors, not the model.
    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws {
        _ = try await context(progress: progress)
    }

    private func context(
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ModelContext {
        if let loaded { return loaded }
        if let loading { return try await loading.value }

        let task = Task<ModelContext, Error> { try await Self.build(progress: progress) }
        loading = task
        defer { loading = nil }
        let built = try await task.value
        loaded = built
        return built
    }

    private static func build(
        progress: (@Sendable (String) -> Void)?
    ) async throws -> ModelContext {
        try await cache.ensure(progress: progress)
        let context = try await loadModel(from: cache.directory, using: FolderTokenizer())
        guard context.model is Qwen3Model else {
            throw Failure.notQwen(String(describing: type(of: context.model)))
        }
        MLXModelCache.limitBufferPool()
        return context
    }

    // MARK: - the two vectors

    /// Which side of the slot a vector is taken from.
    enum Side {
        /// The sub-tokens of the word itself.
        case word
        /// Every token except the word's.
        case around
    }

    /// The mean of one side's token states, L2-normalised.
    ///
    /// `word` must appear in `sentence`; the first occurrence is used.
    /// The tokens of the last `vector` call, for `--word-vector` to print.
    private(set) var lastPicked: [Int] = []
    private(set) var lastCount = 0

    func vector(_ side: Side, of word: String, in sentence: String) async throws -> [Float] {
        let context = try await context()
        guard let model = context.model as? Qwen3Model else {
            throw Failure.notQwen(String(describing: type(of: context.model)))
        }
        let ids = context.tokenizer.encode(text: sentence, addSpecialTokens: false)
        guard let span = Self.span(of: word, in: sentence, using: context.tokenizer, ids: ids)
        else { throw Failure.spanNotFound(word: word, in: sentence) }

        let picked: [Int]
        switch side {
        case .word:   picked = Array(span)
        case .around: picked = (0 ..< ids.count).filter { !span.contains($0) }
        }
        guard !picked.isEmpty else {
            throw Failure.spanNotFound(word: word, in: sentence)
        }
        lastPicked = picked
        lastCount = ids.count

        let states = model.model(MLXArray(ids.map { Int32($0) }, [1, ids.count]))
        let mean = states[0, MLXArray(picked.map { Int32($0) })].mean(axis: 0)
        let unit = mean / MLX.sqrt((mean * mean).sum())
        unit.eval()
        return unit.asType(.float32).asArray(Float.self)
    }

    /// Cosine between two unit vectors of the same length.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0.0
        for i in a.indices { total += Double(a[i]) * Double(b[i]) }
        return total
    }

    // MARK: - finding the word's tokens

    /// The token indices that cover the characters of `word`.
    ///
    /// `swift-transformers` gives no character offsets, so they are rebuilt:
    /// decoding the first k tokens gives the offset after token k, for every k.
    /// That is `offset_mapping` by another route, and it is the only route that
    /// works — counting the tokens of the text before the word and the text
    /// including it disagrees by one whenever a leading space merges into the
    /// word, which is most of the time.
    ///
    /// Refused rather than guessed if the decoded text does not reproduce the
    /// sentence: a span read off a text the tokenizer did not write would pick
    /// the wrong states silently.
    private static func span(
        of word: String, in sentence: String, using tokenizer: any MLXLMCommon.Tokenizer,
        ids: [Int]
    ) -> Range<Int>? {
        guard let found = sentence.range(of: word) else { return nil }
        let from = sentence.distance(from: sentence.startIndex, to: found.lowerBound)
        let upTo = sentence.distance(from: sentence.startIndex, to: found.upperBound)

        var offsets: [Int] = [0]
        offsets.reserveCapacity(ids.count + 1)
        for k in 1 ... ids.count {
            let text = tokenizer.decode(tokenIds: Array(ids[0 ..< k]), skipSpecialTokens: true)
            offsets.append(text.count)
        }
        guard offsets.last == sentence.count else { return nil }

        let covering = (0 ..< ids.count).filter { offsets[$0] < upTo && offsets[$0 + 1] > from }
        guard let first = covering.first, let last = covering.last else { return nil }
        return first ..< (last + 1)
    }

}
