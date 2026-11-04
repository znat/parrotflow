import CoreML
import Foundation

/// What a `returns: json` transform that declares `parse: true` gets as `parse`.
struct ParseField: Encodable, Sendable {
    struct Word: Encodable, Sendable {
        /// Character offset and length into the text, as `Tagger.Token` counts them.
        let at: Int
        let len: Int
        let text: String
        let upos: String
        let feats: [String: String]
        /// 1-based into `words`, 0 for the root of its window.
        let head: Int
        let deprel: String
        let ner: String?
        let tags: [Float]

        enum CodingKeys: String, CodingKey { case at, len, text, upos, feats, head, deprel, ner, tags }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(at, forKey: .at)
            try c.encode(len, forKey: .len)
            try c.encode(text, forKey: .text)
            try c.encode(upos, forKey: .upos)
            try c.encode(feats, forKey: .feats)
            try c.encode(head, forKey: .head)
            try c.encode(deprel, forKey: .deprel)
            try c.encode(ner, forKey: .ner)
            try c.encode(tags.map { (Double($0) * 10_000).rounded() / 10_000 }, forKey: .tags)
        }
    }

    let language: String
    let tagNames: [String]
    let words: [Word]
    /// Not encoded: what `--parse --batch` reports.
    let windows: [Parser.Window]

    enum CodingKeys: String, CodingKey {
        case language, words
        case tagNames = "tag_names"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(language, forKey: .language)
        try c.encode(tagNames, forKey: .tagNames)
        try c.encode(words, forKey: .words)
    }

    /// The text split into words and windows, each window parsed on its own.
    /// Throws `Abstained` when a window does not fit or has no single root.
    static func of(_ text: String, language: String, parser: Parser) throws -> ParseField {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { !WordSplit.isSpace($0) }) else { throw Abstained(.empty, "no words") }
        var found: [WordSplit.Word] = []
        var windows: [Parser.Window] = []
        for window in WordSplit.windows(scalars, language: language, fits: parser.fits) {
            let words = WordSplit.words(scalars, in: window, language: language)
            guard !words.isEmpty else { continue }
            let strings = words.map(\.text)
            guard parser.fits(strings) else { throw Abstained(.subwords, "a window over \(Parser.length) subwords") }
            guard let analysed = try parser.analyse(strings) else { throw Abstained(.tree, "no single root") }
            found += words
            windows.append(analysed)
        }
        return field(text, language: language, words: found, windows: windows, tagNames: parser.tagNames)
    }

    /// One window over words given as they are, joined by single spaces.
    static func of(words strings: [String], language: String, parser: Parser) throws -> ParseField {
        guard !strings.isEmpty else { throw Abstained(.empty, "no words") }
        guard parser.fits(strings) else { throw Abstained(.subwords, "over \(Parser.length) subwords") }
        guard let analysed = try parser.analyse(strings) else { throw Abstained(.tree, "no single root") }
        var words: [WordSplit.Word] = []
        var at = 0
        for string in strings {
            if !words.isEmpty { at += 1 }
            let end = at + string.unicodeScalars.count
            words.append(WordSplit.Word(text: string, scalars: at ..< end))
            at = end
        }
        return field(strings.joined(separator: " "), language: language, words: words,
                     windows: [analysed], tagNames: parser.tagNames)
    }

    private static func field(
        _ text: String, language: String, words: [WordSplit.Word], windows: [Parser.Window], tagNames: [String]
    ) -> ParseField {
        var character: [Int] = []
        for (index, grapheme) in text.enumerated() {
            character += Array(repeating: index, count: grapheme.unicodeScalars.count)
        }
        var out: [Word] = []
        for window in windows {
            let base = out.count
            for (k, word) in window.words.enumerated() {
                let split = words[base + k], ner = window.ner[k]
                let at = character[split.scalars.lowerBound]
                out.append(Word(
                    at: at, len: character[split.scalars.upperBound - 1] - at + 1, text: split.text,
                    upos: word.upos, feats: word.feats, head: word.head == 0 ? 0 : word.head + base,
                    deprel: word.deprel, ner: ner, tags: word.tags
                ))
            }
        }
        return ParseField(language: language, tagNames: tagNames, words: out, windows: windows)
    }

    struct Abstained: LocalizedError {
        enum Code: String { case empty, subwords, tree }
        let code: Code
        let reason: String
        init(_ code: Code, _ reason: String) {
            self.code = code
            self.reason = reason
        }
        var errorDescription: String? { reason }
    }
}

/// The `parse` and `ner` functions of the package `SlotModel` fetches.
@available(macOS 14, *)
actor SyrinxParser {

    static let shared = SyrinxParser()

    /// Cached loads took 0.59 to 1.47 s, plus about 0.2 s for the first prediction.
    static let dictationWait: Double = 2.0

    private var loaded: Parser?
    private var loading: Task<Parser, Error>?
    /// A damaged cache re-fetches 283 MB, so not on every dictation.
    private var retryAfter: Date?
    private var failure: String?
    private static let backoff: TimeInterval = 300

    func warm() {
        guard loaded == nil, loading == nil else { return }
        if let retryAfter, Date() < retryAfter { return }
        let task = start(progress: nil)
        Task {
            let started = Date()
            do {
                _ = try await task.value
                Log.write(String(format: "parser: warmed in %.1fs", Date().timeIntervalSince(started)))
            } catch {
                Log.write("parser: \(error.localizedDescription); transforms that ask for the parse go without it")
            }
        }
    }

    /// For the setup screen's repair button.
    func retryNow() {
        retryAfter = nil
        warm()
    }

    struct Ready {
        let parser: Parser?
        /// Why `parser` is nil.
        let reason: String
    }

    /// A dictation waits only for a cached copy, and at most `seconds`; the
    /// load goes on after that. Without a cache the fetch starts and this
    /// returns at once.
    func ready(within seconds: Double) async -> Ready {
        if let loaded { return Ready(parser: loaded, reason: "") }
        guard SlotModel.isCached else {
            warm()
            return Ready(parser: nil, reason: "parser not downloaded")
        }
        if loading == nil, let retryAfter, Date() < retryAfter {
            return Ready(parser: nil, reason: failure ?? "parser failed to load")
        }
        let task = start(progress: nil)
        let first = First<Result<Parser, Error>?>()
        let outcome = await withCheckedContinuation { continuation in
            first.continuation = continuation
            Task { first.resume(await task.result) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                first.resume(nil)
            }
        }
        switch outcome {
        case .success(let parser)?: return Ready(parser: parser, reason: "")
        case .failure(let error)?: return Ready(parser: nil, reason: error.localizedDescription)
        case nil: return Ready(parser: nil, reason: "parser still loading")
        }
    }

    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws -> Parser {
        if let loaded { return loaded }
        return try await start(progress: progress).value
    }

    private func start(progress: (@Sendable (String) -> Void)?) -> Task<Parser, Error> {
        if let loading { return loading }
        let task = Task<Parser, Error> { try await Self.build(progress: progress) }
        loading = task
        Task { await settle(task) }
        return task
    }

    private func settle(_ task: Task<Parser, Error>) async {
        do {
            loaded = try await task.value
            failure = nil
            ModelDownloads.report(SlotModel.download.id, .installed)
            RetiredModels.prune(.syrinx, in: AppVariant.supportDirectory)
            RetiredModels.prune(.parrotSyrinx, in: AppVariant.supportDirectory)
        } catch {
            // The other process holding the lock lets go on its own; that is not a damaged cache.
            if case SlotModel.Failure.busy = error {} else { retryAfter = Date().addingTimeInterval(Self.backoff) }
            failure = error.localizedDescription
            // A heads file that will not read is the bundle's fault, not the download's.
            if !(error is Parser.Failure) {
                ModelDownloads.report(
                    SlotModel.download.id,
                    .failed(ModelDownloads.failure(error, needs: SlotModel.download.peakLabel))
                )
            }
        }
        loading = nil
    }

    /// Resumes its continuation once, with whichever value comes first.
    private final class First<Value>: @unchecked Sendable {
        var continuation: CheckedContinuation<Value, Never>?
        private let lock = NSLock()

        func resume(_ value: Value) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }
    }

    private static func build(progress: (@Sendable (String) -> Void)?) async throws -> Parser {
        let heads = try Tensors(contentsOf: Parser.headsURL)
        let parser = try await SlotModel.shared.compiled(progress: progress) {
            try Parser(
                parse: try model("parse"), ner: try model("ner"),
                tokenizer: try ScalarBPE(contentsOf: SlotModel.tokenizerDirectory.appendingPathComponent("tokenizer.json")),
                heads: heads
            )
        }
        // The first prediction after a load took 167 to 223 ms against 10 to 16 ms warm.
        _ = try? ParseField.of("I mean it.", language: "en", parser: parser)
        return parser
    }

    /// `.cpuAndGPU`, as for `mask`: compute units are load-bearing.
    private static func model(_ function: String) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.functionName = function
        return try MLModel(contentsOf: SlotModel.compiledURL, configuration: configuration)
    }

    /// The `parse` field for one stage, or nil with a log line saying why.
    static func field(for text: String, language: String, stage: String) async -> ParseField? {
        let ready = await shared.ready(within: dictationWait)
        guard let parser = ready.parser else {
            Log.write("pipeline: \(stage) runs without the parse — \(ready.reason)")
            return nil
        }
        do {
            return try ParseField.of(text, language: language, parser: parser)
        } catch {
            Log.write("pipeline: \(stage) runs without the parse — \(error.localizedDescription)")
            return nil
        }
    }
}
