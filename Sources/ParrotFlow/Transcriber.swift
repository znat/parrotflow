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

    private(set) var status: Status = .idle

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
    func transcribe(
        url: URL, config: Config, app: Pipeline.App? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await prepare(config: config)

        if config.audio.speechGate, try await isSilent(url: url) {
            Log.write("speech gate: no speech detected; not transcribing")
            return ""
        }

        guard let models else { throw TranscriberError.notReady }

        // A finished clip goes through the batch path in one call, not through
        // SlidingWindowAsrManager. That manager is built for a stream whose end
        // has not arrived yet: it decodes in fixed windows, and a clip longer
        // than its chunk gets split and the seam between windows swallows
        // words. It is the reason dictations came back with their endings
        // missing — a 12s clip returned its first sentence and dropped the two
        // after it, reproducibly, from the file on disk.
        //
        // Re-run over the 518 recordings in ~/Recordings: 65 clips came back
        // with more of what was said, several recovering whole clauses; the 65
        // that came back shorter are punctuation and casing, bar two where the
        // old path had been inventing sentences over silence.
        //
        // The batch path decodes a clip up to 15s as a single window and chunks
        // longer ones itself, with the overlap merge FluidAudio's own benchmarks
        // use. Nothing here needs a partial transcript before the recording
        // ends, so there is no reason to pay for one. It is no slower: 12s of
        // audio in 0.2s either way.
        //
        // A manager per clip, not one cached: the decoder state below is
        // per-clip, and a shared manager would carry one clip's state into the
        // next. The models are the expensive part and those are cached.
        let asr = AsrManager(models: models)
        var decoderState = await TdtDecoderState.make(decoderLayers: asr.decoderLayerCount)
        let result = try await asr.transcribe(url, decoderState: &decoderState)
        Trace.current?.recordASR(result)

        return await Self.applyReplacements(
            to: result.text, config: config, app: app, progress: progress
        )
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
        // The boundaries, not just the totals: "the ending was cut off" is
        // answered by where the last segment stops against where the words
        // stop, and the log line above cannot tell you either.
        Trace.current?.recordVAD(
            speech: speech, total: total,
            segments: segments.map { ($0.startTime, $0.endTime) }
        )
        return segments.isEmpty
    }

    /// The last, blunt pass: literal substitutions from the config.
    ///
    /// Runs after vocabulary boosting has had its go, and only helps for terms
    /// that boosting missed. Word-boundary matched and case-insensitive so
    /// "mick" and "Mick" both land, but "Mickey" is left alone.
    /// How names get fixed — see `Replacements`.
    nonisolated static func applyReplacements(
        to text: String, config: Config, app: Pipeline.App? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        await Replacements.apply(to: text, config: config, app: app, progress: progress)
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
