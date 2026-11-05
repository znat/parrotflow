import CoreML
import Foundation

/// What a `returns: json` transform that declares `parse: true` or `parse: vectors` gets as `parse`.
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
        let vector: [Float16]?

        enum CodingKeys: String, CodingKey { case at, len, text, upos, feats, head, deprel, ner, tags, vector }

        /// Base64 of the little-endian float16 values.
        var packedVector: String? {
            guard let vector else { return nil }
            var bytes = Data(capacity: vector.count * 2)
            for value in vector {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
            return bytes.base64EncodedString()
        }

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
            try c.encodeIfPresent(packedVector, forKey: .vector)
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

    var withoutVectors: ParseField {
        ParseField(language: language, tagNames: tagNames, words: words.map {
            Word(at: $0.at, len: $0.len, text: $0.text, upos: $0.upos, feats: $0.feats, head: $0.head,
                 deprel: $0.deprel, ner: $0.ner, tags: $0.tags, vector: nil)
        }, windows: windows)
    }

    /// The text split into words and windows, each window parsed on its own.
    /// Throws `Abstained` when a window does not fit or has no single root.
    static func of(_ text: String, language: String, parser: Parser, vectors: Bool = false) throws -> ParseField {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { !WordSplit.isSpace($0) }) else { throw Abstained(.empty, "no words") }
        var found: [WordSplit.Word] = []
        var windows: [Parser.Window] = []
        for window in WordSplit.windows(scalars, language: language, fits: parser.fits) {
            let words = WordSplit.words(scalars, in: window, language: language)
            guard !words.isEmpty else { continue }
            let strings = words.map(\.text)
            guard parser.fits(strings) else { throw Abstained(.subwords, "a window over \(Parser.length) subwords") }
            guard let analysed = try parser.analyse(strings, vectors: vectors) else {
                throw Abstained(.tree, "no single root")
            }
            try finite(analysed)
            found += words
            windows.append(analysed)
        }
        return field(text, language: language, words: found, windows: windows, tagNames: parser.tagNames)
    }

    /// One window over words given as they are, joined by single spaces.
    static func of(words strings: [String], language: String, parser: Parser, vectors: Bool = false) throws -> ParseField {
        guard !strings.isEmpty else { throw Abstained(.empty, "no words") }
        guard parser.fits(strings) else { throw Abstained(.subwords, "over \(Parser.length) subwords") }
        guard let analysed = try parser.analyse(strings, vectors: vectors) else {
            throw Abstained(.tree, "no single root")
        }
        try finite(analysed)
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

    /// `JSONEncoder` throws on NaN, and one would cost the script its whole envelope.
    private static func finite(_ window: Parser.Window) throws {
        guard window.words.allSatisfy({ $0.tags.allSatisfy(\.isFinite) }) else {
            throw Abstained(.numbers, "a probability that is not a number")
        }
        guard window.vectors?.allSatisfy(\.isFinite) ?? true else {
            throw Abstained(.numbers, "a vector value that is not a number")
        }
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
                    deprel: word.deprel, ner: ner, tags: word.tags,
                    vector: window.vectors.map { Array($0[k * Parser.width ..< (k + 1) * Parser.width]) }
                ))
            }
        }
        return ParseField(language: language, tagNames: tagNames, words: out, windows: windows)
    }

    struct Abstained: LocalizedError {
        enum Code: String { case empty, subwords, tree, numbers }
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

    /// Whether the setup row is the parser's to report: true when no
    /// vocabulary step loads the mask from the same package.
    private var ownsRow = false

    func warm(ownsRow: Bool = false) {
        self.ownsRow = ownsRow
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
    func retryNow(ownsRow: Bool = false) {
        retryAfter = nil
        warm(ownsRow: ownsRow)
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
        let owns = ownsRow
        let task = Task<Parser, Error> { try await Self.build(progress: progress, ownsRow: owns) }
        loading = task
        Task { await settle(task) }
        return task
    }

    private func settle(_ task: Task<Parser, Error>) async {
        do {
            loaded = try await task.value
            failure = nil
            RetiredModels.prune(.syrinx, in: AppVariant.supportDirectory)
            RetiredModels.prune(.parrotSyrinx, in: AppVariant.supportDirectory)
        } catch {
            // The other process holding the lock lets go on its own; that is not a damaged cache.
            if case SlotModel.Failure.busy = error {} else { retryAfter = Date().addingTimeInterval(Self.backoff) }
            failure = error.localizedDescription
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

    /// The setup row is the package's. The parser writes to it for a fetch it
    /// started itself, or when no mask load will.
    private static func build(progress: (@Sendable (String) -> Void)?, ownsRow: Bool) async throws -> Parser {
        let weights = try Parser.Weights(contentsOf: Parser.headsURL)
        let reports = try await SlotModel.onDisk(progress: progress) || ownsRow
        let parser: Parser
        do {
            parser = try Parser(
                parse: try model("parse"), ner: try model("ner"),
                tokenizer: try ScalarBPE(contentsOf: SlotModel.tokenizerDirectory.appendingPathComponent("tokenizer.json")),
                weights: weights
            )
        } catch {
            if reports {
                ModelDownloads.report(
                    SlotModel.download.id,
                    .failed(ModelDownloads.failure(error, needs: SlotModel.download.peakLabel))
                )
            }
            throw error
        }
        if reports { ModelDownloads.report(SlotModel.download.id, .installed) }
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
    static func field(for text: String, language: String, stage: String, vectors: Bool) async -> ParseField? {
        guard text.unicodeScalars.contains(where: { !WordSplit.isSpace($0) }) else { return nil }
        let ready = await shared.ready(within: dictationWait)
        guard let parser = ready.parser else {
            Log.write("pipeline: \(stage) runs without the parse — \(ready.reason)")
            return nil
        }
        do {
            return try ParseField.of(text, language: language, parser: parser, vectors: vectors)
        } catch {
            Log.write("pipeline: \(stage) runs without the parse — \(error.localizedDescription)")
            return nil
        }
    }
}

/// The parse of each exact text for one pipeline run, so two steps on the
/// same text parse it once. The vectors come out of the same forward pass as
/// the tree, so a step that asks for the tree alone gets the vectors parse
/// without them, and its envelope is what a fresh parse would have given.
final class ParseCache: @unchecked Sendable {
    /// Keyed by bytes: `String` equality would match "café" composed and
    /// decomposed, and hand a script word offsets into the other spelling.
    private var parsed: [Data: (field: ParseField, vectors: Bool)] = [:]

    func field(for text: String, language: String, stage: String, vectors: Bool) async -> ParseField? {
        let key = Data((language + "\u{1F}" + text).utf8)
        if let hit = parsed[key], hit.vectors || !vectors {
            return vectors || !hit.vectors ? hit.field : hit.field.withoutVectors
        }
        let field = await SyrinxParser.field(for: text, language: language, stage: stage, vectors: vectors)
        if let field { parsed[key] = (field, vectors) }
        return field
    }
}
