import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT v3 transcription. Models are downloaded on first use.
///
/// Acoustic vocabulary boosting was tried and removed. Measured against the
/// recordings on disk it altered 48 of 50 transcripts that contained none of
/// its terms — "Hey there, my name is Nathan." became "Matthieu my name is
/// Nathan." — on the streaming path, on the batch path FluidAudio's own
/// benchmark uses, and with the similarity threshold swept to 0.90. It is
/// built for long-form audio with hundreds of domain terms, where 15% WER is
/// an acceptable price; a four-word list against ordinary speech is the
/// opposite case. `transcription.replacements` does the job instead.
@available(macOS 14, *)
actor Transcriber {

    enum Status: Equatable {
        case idle
        case downloading(String)
        case loading
        case ready
        case failed(String)
    }

    /// The stock `.default` config is built for long-form streaming, and holds
    /// text as provisional until `minContextForConfirmation: 10s` has passed
    /// and confidence clears 0.85. Both gates exist to stop a live transcript
    /// rewriting itself in front of the reader.
    ///
    /// Dictation clips are mostly shorter than 10s, and we only ever hand over
    /// a finished recording, so neither buys anything here.
    private static let dictationConfig = SlidingWindowAsrConfig(
        chunkSeconds: 11.0,
        hypothesisChunkSeconds: 11.0,  // one pass: the clip is already finished
        leftContextSeconds: 2.0,
        rightContextSeconds: 2.0,
        minContextForConfirmation: 0.3,
        confirmationThreshold: 0.0
    )

    private(set) var status: Status = .idle

    // Models are cached; the manager is not. SlidingWindowAsrManager holds its
    // input AsyncStream in a `let` created at init, and finish() closes that
    // stream for good — startStreaming() cannot re-arm it. A reused manager
    // therefore reads from a dead stream, processes no audio, and returns
    // whatever text was left over from the previous clip. Measured: the second
    // and every later dictation returned text left over from the previous one.
    private var vad: VadManager?
    private var models: AsrModels?

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
        if models == nil {
            setStatus(.downloading("speech model"))
            models = try await AsrModels.downloadAndLoad(
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.reportDownload("speech model", progress) }
                }
            )
        }

        if config.audio.speechGate, vad == nil {
            setStatus(.downloading("voice detector"))
            vad = try? await VadManager(config: .default)
            if vad == nil { Log.write("speech gate: VAD unavailable; transcribing everything") }
        }

        setStatus(.ready)
    }

    /// A manager is good for exactly one clip — see the note on `models`.
    private func makeManager() async throws -> SlidingWindowAsrManager {
        guard let models else { throw TranscriberError.notReady }

        let manager = SlidingWindowAsrManager(config: Self.dictationConfig)
        try await manager.loadModels(models)
        return manager
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


    // MARK: - Transcription

    /// Transcribes a finished recording. Returns the cleaned-up text.
    func transcribe(url: URL, config: Config) async throws -> String {
        try await prepare(config: config)
        let manager = try await makeManager()

        if config.audio.speechGate, try await isSilent(url: url) {
            Log.write("speech gate: no speech detected; not transcribing")
            return ""
        }

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

    /// True when the clip holds no speech worth transcribing.
    ///
    /// An acoustic model asked to decode silence decodes *something* — five
    /// clips in one session of real use, all under 0.51s of stray hotkey
    /// press, came back as "Yeah." It is the same mechanism behind Whisper's
    /// "Thank you for watching". A hallucination cannot appear if the decoder
    /// never runs, so silence is caught before it gets there rather than
    /// filtered out of the text afterwards.
    ///
    /// The test is presence, not duration. On the clips that produced the
    /// artifacts, VAD found *zero* speech — 0.00s across 0 segments — while
    /// the shortest genuine utterance held 0.34s across one. There is no
    /// threshold to tune between those, and any threshold would eventually
    /// eat a real one-word answer. So a single detected segment is enough to
    /// let a clip through, however brief.
    ///
    /// Fails open: if the detector is unavailable the clip is transcribed.
    /// Losing real speech is far worse than an occasional stray "Yeah."
    private func isSilent(url: URL) async throws -> Bool {
        guard let vad else { return false }

        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return false }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return false }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard !samples.isEmpty else { return true }

        let segments = try await vad.segmentSpeech(samples)
        let speech = segments.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        let total = Double(samples.count) / 16000

        Log.write(String(
            format: "speech gate: %.2fs speech in %.2fs (%d segment(s))",
            speech, total, segments.count
        ))
        return segments.isEmpty
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
