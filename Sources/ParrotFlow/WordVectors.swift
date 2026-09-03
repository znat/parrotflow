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
/// Qwen and not the shipped ModernBERT. Eight models were scored on the same 59
/// proposals; Qwen is the only one that never wrote a name over an ordinary
/// word, at any threshold. ModernBERT's own vectors veto half the correct
/// writes. 4-bit keeps the property and is 4.6x faster than fp32.
@available(macOS 14, *)
actor WordVectors {

    static let shared = WordVectors()

    /// The row the setup screen draws for it.
    static let download = ModelDownload(
        id: "word-vectors", name: "Qwen3 Embedding 0.6B", megabytes: 335, peak: 335,
        group: .language, blocking: false,
        costOfFailure: "the sentence gate stands aside"
    )

    private static let repository = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// `model.safetensors.index.json` is not in the repository — the weights
    /// are one file. Listing it would fail the download on `unlisted`.
    private static let files = [
        "config.json",
        "model.safetensors",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "vocab.json",
        "merges.txt",
    ]

    static var directory: URL {
        AppVariant.supportDirectory
            .appendingPathComponent("models/qwen3-embedding-0.6b-4bit", isDirectory: true)
    }

    /// Beside the cache directory, not inside it, so a fetch that clears the
    /// cache does not delete a lock somebody is holding.
    private static var lockURL: URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent("qwen3-embedding.lock")
    }

    enum Failure: LocalizedError {
        case busy
        case notQwen(String)
        case spanNotFound(word: String, in: String)

        var errorDescription: String? {
            switch self {
            case .busy:
                return "another ParrotFlow process is fetching the word-vector model"
            case .notQwen(let kind):
                return "the word-vector model loaded as \(kind), not Qwen3"
            case .spanNotFound(let word, let sentence):
                return "\"\(word)\" has no clean token span in \"\(sentence)\""
            }
        }
    }

    static var isCached: Bool {
        files.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

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
        do {
            let built = try await task.value
            loaded = built
            ModelDownloads.report(Self.download.id, .installed)
            return built
        } catch {
            ModelDownloads.report(
                Self.download.id,
                .failed(ModelDownloads.failure(error, needs: Self.download.peakLabel))
            )
            throw error
        }
    }

    /// Deletes the cache, so the next `prepare` fetches it again. `build`
    /// skips the fetch whenever `isCached` is true, weights that load as the
    /// wrong model included.
    static func discardCache() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func build(
        progress: (@Sendable (String) -> Void)?
    ) async throws -> ModelContext {
        if !isCached { try await underLock { try await fetch(progress: progress) } }
        let context = try await loadModel(from: directory, using: FolderTokenizer())
        guard context.model is Qwen3Model else {
            throw Failure.notQwen(String(describing: type(of: context.model)))
        }
        return context
    }

    private static func underLock(_ body: () async throws -> Void) async throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let handle = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { throw Failure.busy }
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        try await body()
    }

    /// Fetches into a staging directory and moves the result into place, so a
    /// half-written cache never loads. Staging sits inside `directory` to keep
    /// the move a rename on one volume.
    private static func fetch(progress: (@Sendable (String) -> Void)?) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let left = try? manager.contentsOfDirectory(atPath: directory.path)
        for name in left ?? [] where name.hasPrefix(".staging-") {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
        let staging = directory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let reported = Reported()
        ModelDownloads.report(download.id, .downloading(percent: nil))
        try await HubDownload.fetch(repo: repository, paths: files, into: staging) { fraction in
            let percent = Int((fraction * 100).rounded())
            guard reported.advanced(to: percent) else { return }
            ModelDownloads.report(download.id, .downloading(percent: percent))
            progress?("word vectors \(percent)%")
        }
        for name in files {
            let target = directory.appendingPathComponent(name)
            try? manager.removeItem(at: target)
            try manager.moveItem(at: staging.appendingPathComponent(name), to: target)
        }
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

    /// The percentage last reported. A class because the progress closure is
    /// `@Sendable` and escapes.
    private final class Reported: @unchecked Sendable {
        private var last = -1
        private let lock = NSLock()

        func advanced(to percent: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard percent > last else { return false }
            last = percent
            return true
        }
    }
}

/// `AutoTokenizer` over a folder, as the one protocol `loadModel` needs.
///
/// `MLXHuggingFace` provides this behind a macro, and swift-syntax with it.
/// This is the whole of what that macro expands to for the loading path.
@available(macOS 14, *)
private struct FolderTokenizer: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Adapter(try await AutoTokenizer.from(modelFolder: directory))
    }

    private struct Adapter: MLXLMCommon.Tokenizer, @unchecked Sendable {
        let upstream: any Tokenizers.Tokenizer

        init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            // Nothing here holds a conversation. The vocabulary stage sends one
            // sentence and reads the states back.
            []
        }
    }
}
