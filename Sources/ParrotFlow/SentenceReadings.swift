import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Reads one boundary three ways and says which reading the language model
/// prefers.
///
/// For `…the LLM with. The vocabulary is slower` the three readings are
///
///     ". The vocabulary is slower"     the period is real
///     " the vocabulary is slower"      the pause cut one sentence in two
///     ", the vocabulary is slower"     it is really a comma
///
/// The first reading is the mark the transcriber actually wrote, so a
/// `word? Capital` boundary is read `"? Word"`, `", word"` and `" word"`. A
/// boundary with no mark is read four ways — see `bare` — because the text as
/// decoded is then a candidate rather than what happens by default.
/// Reading every configured ender at every boundary was measured too and is
/// worse: 259 of 325 question cuts repaired against 265, for a fourth forward
/// pass.
///
/// Each is scored as `sum of log P(token | everything before it)` over the
/// continuation, **divided by the token count**, and the highest wins. There is
/// no threshold and nothing to calibrate. On summed log-probability instead of
/// per-token the joined reading wins by being shortest — 97% of cuts repaired
/// and 33 real endings destroyed.
///
/// The comma is a reading, not a term in a subtraction. 26% of real sentence
/// endings pick it, and that is why none of them picks `join`. Scoring
/// `max(mark) - log P(next)` instead gives 64% against this shape's 81%.
///
/// `mlx-community/Qwen3-0.6B-Base-4bit`, not the DWQ checkpoint: despite the
/// name that one is a quant of the *instruct* model and repairs 76%.
///
/// The three readings go into one padded batch, which reads the weights once:
/// 50 ms against 70 ms for three separate passes. A shared KV cache for the
/// prefix is slower still — one forward costs 23 ms whatever the length at
/// 0.6B, so caching the prefix adds a fourth pass and saves nothing.
@available(macOS 14, *)
actor SentenceReadings {

    static let shared = SentenceReadings()

    /// `model.safetensors.index.json` is absent from this repository — the
    /// weights are one file — and listing it would fail the fetch.
    static let cache = MLXModelCache(
        repository: "mlx-community/Qwen3-0.6B-Base-4bit",
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
            .appendingPathComponent("models/qwen3-0.6b-base-4bit", isDirectory: true),
        lockURL: AppVariant.supportDirectory
            .appendingPathComponent("models/qwen3-0.6b-base.lock"),
        label: "sentence readings"
    )

    static var directory: URL { cache.directory }
    static var isCached: Bool { cache.isCached }

    /// The key of the reading that removes the period.
    static let join = "join"

    /// The key of the reading that leaves a bare capital exactly as decoded.
    static let asDecoded = "as-decoded"

    /// Marks after which the next word keeps its capital.
    static let enders: Set<String> = [".", "?", "!"]

    /// Words kept either side of the boundary, the next word counting as the
    /// first on the right. The measurement was made at 12.
    static let radius = 12

    enum Failure: LocalizedError {
        case notQwen(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notQwen(let kind):
                return "the sentence model loaded as \(kind), not Qwen3"
            case .empty:
                return "sentence readings: nothing either side of the boundary"
            }
        }
    }

    // MARK: - the three readings

    /// One reading of the boundary: the mark written there, and whether the
    /// word after it keeps its capital.
    struct Reading: Sendable {
        let key: String
        let mark: String
        let capital: Bool
    }

    /// One reading, scored.
    struct Score: Sendable {
        let key: String
        /// Log-probability per token of the continuation.
        let mean: Double
        let tokens: Int
        /// True when the boundary character merged into the last prefix token,
        /// so the score starts at the first token that actually differs.
        let retokenised: Bool
    }

    /// The readings, in the order the winner is picked from: the mark found in
    /// the text, then the configured marks that do not end a sentence, then
    /// the join. First past the post, so an exact tie leaves the boundary
    /// alone.
    ///
    /// The other enders are left out. A boundary already carries one, and
    /// swapping a period for a question mark is not a repair this stage makes.
    static func readings(found: String, marks: [String]) -> [Reading] {
        guard !found.isEmpty else { return bare(marks: marks) }
        return ([found] + marks.filter { !enders.contains($0) && $0 != found })
            .map { Reading(key: $0, mark: $0, capital: enders.contains($0)) }
            + [Reading(key: join, mark: "", capital: false)]
    }

    /// The readings of a boundary that holds no mark at all — a capital the
    /// transcriber wrote after a pause, with nothing in front of it.
    ///
    /// Four, not three. The text as decoded is a reading of its own here: with
    /// no mark to remove, "leave it alone" is a real candidate rather than the
    /// thing that happens when a mark wins. Only `join` writes anything.
    ///
    /// One ender, not every configured one. Which sentence mark belongs here is
    /// a question this stage does not answer — it never inserts one — so a
    /// second ender would buy a fifth forward pass and no decision.
    static func bare(marks: [String]) -> [Reading] {
        (marks.first { enders.contains($0) }.map {
            [Reading(key: $0, mark: $0, capital: true)]
        } ?? [])
        + [Reading(key: asDecoded, mark: "", capital: true)]
        + marks.filter { !enders.contains($0) }.map {
            Reading(key: $0, mark: $0, capital: false)
        }
        + [Reading(key: join, mark: "", capital: false)]
    }

    /// The shared prefix and one continuation per reading.
    ///
    /// The left side loses its trailing mark, so a caller that kept it and one
    /// that did not build the same window.
    static func build(
        left: String, right: String, found: String, marks: [String]
    ) -> (prefix: String, continuations: [String])? {
        var bare = left
        while let last = bare.last, enders.contains(String(last)) { bare.removeLast() }
        let leftWords = bare.split(whereSeparator: \.isWhitespace).map(String.init)
        let rightWords = right.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return nil }
        let prefix = leftWords.suffix(radius).joined(separator: " ")
        let first = rightWords[0]
        let up = first.prefix(1).uppercased() + first.dropFirst()
        let lo = first.prefix(1).lowercased() + first.dropFirst()
        let rest = rightWords.count > 1
            ? Array(rightWords[1 ..< min(radius, rightWords.count)]) : []
        let tail = rest.isEmpty ? "" : " " + rest.joined(separator: " ")
        let continuations = readings(found: found, marks: marks).map {
            "\($0.mark) \($0.capital ? up : lo)\(tail)"
        }
        return (prefix, continuations)
    }

    // MARK: - loading

    private var loaded: ModelContext?

    /// The load in flight, if any. Actor isolation stops a torn read of
    /// `loaded`, not two callers both finding it nil across the same `await`.
    private var loading: Task<ModelContext, Error>?

    /// True once the weights are in memory.
    ///
    /// The stage asks before it runs. A dictation must never wait on a 320 MB
    /// download and a 1.3 s load: the boundaries of that one dictation are left
    /// alone and the warm starts instead.
    var isLoaded: Bool { loaded != nil }

    /// When a failed load may be tried again. A held `flock` on the model cache
    /// is the failure this exists for: another process is fetching, and the
    /// next dictation would otherwise never look again. Not a latch — but not
    /// every dictation either, because a damaged cache makes the load re-fetch
    /// 320 MB.
    private var retryAfter: Date?
    private static let backoff: TimeInterval = 300

    /// Starts the load if nothing is doing it, and returns at once.
    func warm() {
        guard loaded == nil, loading == nil else { return }
        if let retryAfter, Date() < retryAfter { return }
        Task { [weak self] in
            do { try await self?.prepare() } catch {
                await self?.hold(after: error)
            }
        }
    }

    private func hold(after error: Error) {
        retryAfter = Date().addingTimeInterval(Self.backoff)
        Log.write("sentence readings: \(error.localizedDescription);"
            + " boundaries are left as decoded until they load")
    }

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

    // MARK: - scoring

    /// The three readings of one boundary, scored.
    func read(
        left: String, right: String, found: String, marks: [String]
    ) async throws -> [Score] {
        guard let built = Self.build(
            left: left, right: right, found: found, marks: marks
        ) else {
            throw Failure.empty
        }
        let context = try await context()
        guard let model = context.model as? Qwen3Model else {
            throw Failure.notQwen(String(describing: type(of: context.model)))
        }
        return Self.score(
            prefix: built.prefix, continuations: built.continuations,
            keys: Self.readings(found: found, marks: marks).map(\.key),
            model: model, tokenizer: context.tokenizer
        )
    }

    /// Every reading padded into one batch and scored in one forward pass.
    ///
    /// Right-padded with the prefix's last token, causal attention, and the pad
    /// columns are never scored, so the padding cannot reach a score.
    ///
    /// The prefix does not always tokenize the same inside the full sequence:
    /// on 2 of 972 bench sequences the boundary character merges into the last
    /// prefix token — the case is a left side ending `names).`. Slicing the
    /// continuation at the prefix's length would then score the wrong tokens,
    /// so the scored span starts at the first token that actually differs.
    private static func score(
        prefix: String, continuations: [String], keys: [String],
        model: Qwen3Model, tokenizer: any MLXLMCommon.Tokenizer
    ) -> [Score] {
        let prefixIds = tokenizer.encode(text: prefix, addSpecialTokens: false)
        let p = prefixIds.count
        let fulls = continuations.map {
            tokenizer.encode(text: prefix + $0, addSpecialTokens: false)
        }
        let width = fulls.map(\.count).max() ?? 0
        guard width > 0, p > 0 else { return [] }

        let pad = Int32(prefixIds.last ?? 0)
        var flat: [Int32] = []
        flat.reserveCapacity(width * fulls.count)
        for full in fulls {
            flat.append(contentsOf: full.map { Int32($0) })
            flat.append(contentsOf: Array(repeating: pad, count: width - full.count))
        }
        let logits = model(MLXArray(flat, [fulls.count, width]), cache: nil)

        var starts: [Int] = []
        var totals: [MLXArray] = []
        for (b, full) in fulls.enumerated() {
            let shared = zip(full, prefixIds).prefix { $0.0 == $0.1 }.count
            let from = max(1, min(shared, full.count - 1))
            starts.append(from)
            let n = full.count - from
            let slice = logits[b, (from - 1) ..< (full.count - 1)].asType(.float32)
            let targets = MLXArray(full[from...].map { Int32($0) }, [n, 1])
            let picked = takeAlong(slice, targets, axis: 1)
            totals.append((picked - logSumExp(slice, axis: 1, keepDims: true)).sum())
        }
        let stackedTotals = stacked(totals)
        stackedTotals.eval()
        let sums = stackedTotals.asArray(Float.self)

        return keys.indices.map { i in
            let n = fulls[i].count - starts[i]
            return Score(
                key: keys[i], mean: Double(sums[i]) / Double(n), tokens: n,
                retokenised: starts[i] != p
            )
        }
    }
}
