import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT transcription with custom-vocabulary boosting.
///
/// Two model sets are involved, and both are downloaded on first use:
///
/// - **Parakeet TDT v3** does the transcribing.
/// - **CTC 110M** backs the keyword spotter. It's only pulled when the config
///   actually lists vocabulary terms, because without terms it does nothing.
///
/// The vocabulary path runs through `SlidingWindowAsrManager`. That is not a
/// preference — as of FluidAudio 0.15.5 it is the only manager that exposes
/// `configureVocabularyBoosting`. The batch `AsrManager.transcribe(_:customVocabulary:)`
/// shown in FluidAudio's own documentation does not exist in any released
/// version. Worth re-checking on upgrade.
///
/// See `tokenize(_:using:)` for the non-obvious step that makes any of it work.
@available(macOS 14, *)
actor Transcriber {

    enum Status: Equatable {
        case idle
        case downloading(String)
        case loading
        case ready
        case failed(String)
    }

    /// The stock `.default` config is built for long-form streaming and gates
    /// vocabulary rescoring behind `minContextForConfirmation: 10s` plus a 0.85
    /// confidence floor. Dictation clips are usually shorter than that, so with
    /// the defaults the spotter never runs at all and vocabulary silently does
    /// nothing — measured: a 6.3 s clip got zero boosting until these dropped.
    ///
    /// Both gates exist to stop a live transcript rewriting itself in front of
    /// the user. We only ever hand over a finished clip, so neither buys us
    /// anything.
    private static let dictationConfig = SlidingWindowAsrConfig(
        chunkSeconds: 11.0,
        hypothesisChunkSeconds: 11.0,  // one pass: the clip is already finished
        leftContextSeconds: 2.0,
        rightContextSeconds: 2.0,
        minContextForConfirmation: 0.3,
        confirmationThreshold: 0.0
    )

    private(set) var status: Status = .idle

    private var manager: SlidingWindowAsrManager?
    private var loadedVocabulary: [Config.VocabularyTerm] = []

    /// Reported on the main queue so the menu bar can show download progress.
    nonisolated let onStatusChange: @Sendable (Status) -> Void

    init(onStatusChange: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.onStatusChange = onStatusChange
    }

    private func setStatus(_ new: Status) {
        status = new
        onStatusChange(new)
    }

    // MARK: - Model loading

    /// Downloads and loads models if needed. Safe to call repeatedly; it only
    /// redoes work when the vocabulary has actually changed.
    func prepare(config: Config) async throws {
        let vocabulary = config.transcription.vocabulary
        if manager != nil, vocabulary == loadedVocabulary {
            return
        }

        setStatus(.downloading("speech model"))

        let manager = SlidingWindowAsrManager(config: Self.dictationConfig)
        try await manager.loadModels { [weak self] progress in
            guard let self else { return }
            Task { await self.reportDownload("speech model", progress) }
        }

        if !vocabulary.isEmpty {
            setStatus(.downloading("keyword spotter"))
            let ctcModels = try await CtcModels.downloadAndLoad()

            let tokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m)
            )
            let terms = Self.tokenize(vocabulary, using: tokenizer)
            setStatus(.loading)
            try await manager.configureVocabularyBoosting(
                vocabulary: CustomVocabularyContext(terms: terms),
                ctcModels: ctcModels
            )
        }

        self.manager = manager
        self.loadedVocabulary = vocabulary
        setStatus(.ready)
    }

    private var lastReportedPercent: Int = -1

    private func reportDownload(_ label: String, _ progress: DownloadProgress) {
        // The handler fires far more often than the percentage changes; without
        // this the status churns hundreds of times per point.
        let percent = Int((progress.fractionCompleted * 100).rounded())
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        setStatus(.downloading("\(label) \(percent)%"))
    }


    /// Turns config terms into spotter-ready terms.
    ///
    /// The tokenization is not optional. `CtcKeywordSpotter` does
    /// `term.ctcTokenIds ?? term.tokenIds` and `continue`s when both are nil —
    /// so a term built as `CustomVocabularyTerm(text:)`, which is exactly what
    /// FluidAudio's documentation shows, is silently skipped and the spotter
    /// reports zero detections with no warning. Only the file-loading factory
    /// `loadWithCtcTokens(from:)` tokenizes, and we take terms from YAML.
    static func tokenize(
        _ vocabulary: [Config.VocabularyTerm],
        using tokenizer: CtcTokenizer
    ) -> [CustomVocabularyTerm] {
        vocabulary.compactMap { term in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                aliases: term.aliases.isEmpty ? nil : term.aliases,
                ctcTokenIds: ids
            )
        }
    }

    // MARK: - Transcription

    /// Transcribes a finished recording. Returns the cleaned-up text.
    func transcribe(url: URL, config: Config) async throws -> String {
        try await prepare(config: config)
        guard let manager else { throw TranscriberError.notReady }

        let file = try AVAudioFile(forReading: url)
        try await manager.startStreaming(source: .microphone)

        // Feed the whole clip through, then let the manager drain. Chunking at
        // 1 s keeps buffers small without introducing boundaries the spotter
        // would care about — it sees the accumulated window, not these chunks.
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                break
            }
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            await manager.streamAudio(buffer)
        }

        let raw = try await manager.finish()
        return Self.applyReplacements(to: raw, config: config)
    }

    /// The last, blunt pass: literal substitutions from the config.
    ///
    /// Runs after vocabulary boosting has had its go, and only helps for terms
    /// that boosting missed. Word-boundary matched and case-insensitive so
    /// "mick" and "Mick" both land, but "Mickey" is left alone.
    nonisolated static func applyReplacements(to text: String, config: Config) -> String {
        var output = text
        for (from, to) in config.transcription.replacements {
            guard let pattern = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: from))\\b",
                options: [.caseInsensitive]
            ) else { continue }
            output = pattern.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: NSRegularExpression.escapedTemplate(for: to)
            )
        }
        return output
    }
}

enum TranscriberError: LocalizedError {
    case notReady
    case unsupportedSystem

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The speech model isn't loaded yet."
        case .unsupportedSystem:
            return "Transcription needs macOS 14 or later."
        }
    }
}
