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

        var gated: SpeechGate?
        if config.audio.speechGate {
            gated = try await runSpeechGate(url: url)
            if let gated, gated.segments.isEmpty {
                Log.write("speech gate: no speech detected; not transcribing")
                return ""
            }
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

        // Above 15s that batch path still chunks — 14.88s windows on a 12.88s
        // stride — so the seam is only gone for clips that fit one window. A
        // long pause mid-dictation can leave a whole window holding nothing
        // but room tone and the last second of speech, and such a window
        // decodes to nothing: measured on a 37.3s clip whose speaker paused
        // 13.9s, where windows 1 and 2 alone returned exactly the text that
        // was delivered and window 3 — the one holding "view transforms" —
        // returned empty.
        var result = try await asr.transcribe(url, decoderState: &decoderState)

        // Closing the pause up and decoding again puts those words in a window
        // with speech either side of them. It is a retry rather than the first
        // thing tried, because moving the windows is not free: done to every
        // long-pause clip it changed 32 of 1219 in the archive, and one of
        // those changes was a *new* dropped ending — the same bug, moved. So
        // it runs only when the gate can see that this clip lost its tail, and
        // only sticks when it recovers speech that the first pass missed.
        // Every clip that decoded to the end is left exactly as it was.
        if let gated, Self.droppedTail(result, gate: gated), let closed = Self.closeLongPauses(gated) {
            var retryState = await TdtDecoderState.make(decoderLayers: asr.decoderLayerCount)
            let raw = try await asr.transcribe(closed.samples, decoderState: &retryState)
            let retried = Self.restoreTimings(raw, closed: closed, seconds: gated.seconds)
            if Self.lastWordEnd(retried) > Self.lastWordEnd(result) {
                Log.write(String(
                    format: "decoder stopped %.2fs before the speech did; "
                        + "closed %d long pause(s) and recovered to %.2fs",
                    Self.lastSpeechEnd(gated) - Self.lastWordEnd(result),
                    closed.pauses, Self.lastWordEnd(retried)
                ))
                result = retried
            }
        }
        Trace.current?.recordASR(result, model: Repo.parakeetV3.rawValue)

        return await Self.applyReplacements(
            to: result.text, config: config, app: app, progress: progress
        )
    }

    /// What the speech gate found: the clip's samples and its speech
    /// boundaries, kept rather than reduced to a yes/no. The decoder wants
    /// both — see `closeLongPauses`.
    struct SpeechGate {
        let samples: [Float]
        let segments: [(start: Double, end: Double)]
        /// False when the clip is not the 16 kHz mono the recorder writes, in
        /// which case `samples` must not be handed to the decoder directly:
        /// the URL path resamples and this one cannot.
        let decodable: Bool

        var seconds: Double { Double(samples.count) / Transcriber.sampleRate }
    }

    /// Runs the speech gate, or returns nil when there is no detector to run —
    /// which is the fail-open case, and leaves the clip to be decoded whole.
    /// No segments means no speech worth transcribing.
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
    private func runSpeechGate(url: URL) async throws -> SpeechGate? {
        guard let vad else { return nil }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return nil }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let decodable = format.sampleRate == Self.sampleRate && format.channelCount == 1
        guard !samples.isEmpty else {
            return SpeechGate(samples: samples, segments: [], decodable: decodable)
        }

        let segments = try await vad.segmentSpeech(samples)
        let speech = segments.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        let total = Double(samples.count) / Self.sampleRate

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
        return SpeechGate(
            samples: samples,
            segments: segments.map { ($0.startTime, $0.endTime) },
            decodable: decodable
        )
    }

    // MARK: - Closing long pauses

    static let sampleRate = 16_000.0

    /// How far the decoder may stop short of the last speech the gate heard
    /// before the ending counts as dropped rather than trimmed.
    ///
    /// The two are not close together, which is what makes this checkable
    /// rather than tunable. Across the archive the ordinary distance between
    /// the last word and the last segment is under 2s — VAD pads a boundary,
    /// and a final consonant is not a word — while the clip that lost its
    /// ending sat at 15.6s. Nothing lives in between.
    static let droppedTailSeconds = 3.0

    /// Where the decoder stopped, and where the gate heard speech stop.
    nonisolated static func lastWordEnd(_ result: ASRResult) -> Double {
        result.tokenTimings?.last?.endTime ?? 0
    }

    nonisolated static func lastSpeechEnd(_ gate: SpeechGate) -> Double {
        gate.segments.last?.end ?? 0
    }

    /// True when the decoder stopped well before the speech did — the symptom
    /// this whole retry exists for, and the only thing that triggers it.
    nonisolated static func droppedTail(_ result: ASRResult, gate: SpeechGate) -> Bool {
        guard !gate.segments.isEmpty, result.tokenTimings?.isEmpty == false else { return false }
        return lastSpeechEnd(gate) - lastWordEnd(result) > droppedTailSeconds
    }

    /// Only a pause approaching the decoder's own 14.88s window can starve one
    /// of speech, and only a starved window decodes to nothing. Below this a
    /// pause is just someone thinking mid-sentence, the windows either side of
    /// it still hold plenty of speech, and touching the audio would be all risk
    /// and no benefit — a sweep of the archive with this at 2s changed 166 of
    /// 1219 clips, most of which were never at risk. At 8s it is 33.
    static let minPauseToClose = 8.0

    /// What a closed pause is cut down to, half kept on each side so a sentence
    /// boundary still sounds like one.
    ///
    /// Measured on the clip that prompted this: the tail came back at every
    /// residual pause from 0s to 4s and was lost at the original 13.9s, so the
    /// value is picked from the middle of a wide plateau rather than tuned to
    /// an edge.
    static let maxPauseSeconds = 2.0

    /// A clip with its long internal pauses cut out, and the map back to where
    /// its audio came from.
    struct ClosedClip {
        let samples: [Float]
        /// One per surviving run, in seconds: where it sits now, where it sat
        /// in the recording, and how long it is.
        let pieces: [(now: Double, was: Double, length: Double)]
        let pauses: Int

        var seconds: Double { Double(samples.count) / Transcriber.sampleRate }
    }

    /// Cuts the middle out of any pause longer than `minPauseToClose`, leaving
    /// `maxPauseSeconds` of it behind.
    ///
    /// Returns nil — meaning "decode the clip as it is" — for everything that
    /// cannot hit the seam: clips that fit a single decoder window, clips whose
    /// pauses are all short, and clips not in the recorder's own format. That
    /// nil is most of them, and it is what keeps this off the common path.
    nonisolated static func closeLongPauses(_ gate: SpeechGate) -> ClosedClip? {
        guard gate.decodable else { return nil }
        // One window, no seam, nothing to fix.
        guard gate.samples.count > ASRConstants.maxModelSamples else { return nil }
        guard gate.segments.count > 1 else { return nil }

        let keep = maxPauseSeconds / 2
        let count = gate.samples.count
        func index(_ seconds: Double) -> Int {
            min(max(Int((seconds * sampleRate).rounded()), 0), count)
        }

        var runs: [Range<Int>] = []
        var cursor = 0
        var pauses = 0
        for i in 1..<gate.segments.count {
            let pause = gate.segments[i].start - gate.segments[i - 1].end
            guard pause > minPauseToClose else { continue }
            let cut = index(gate.segments[i - 1].end + keep)
            let resume = index(gate.segments[i].start - keep)
            guard cut > cursor, resume > cut else { continue }
            runs.append(cursor..<cut)
            cursor = resume
            pauses += 1
        }
        guard pauses > 0 else { return nil }
        if cursor < count { runs.append(cursor..<count) }

        var samples: [Float] = []
        samples.reserveCapacity(runs.reduce(0) { $0 + $1.count })
        var pieces: [(now: Double, was: Double, length: Double)] = []
        for run in runs {
            pieces.append((
                now: Double(samples.count) / sampleRate,
                was: Double(run.lowerBound) / sampleRate,
                length: Double(run.count) / sampleRate
            ))
            samples.append(contentsOf: gate.samples[run])
        }
        return ClosedClip(samples: samples, pieces: pieces, pauses: pauses)
    }

    /// Puts the word timings back on the recording's own clock.
    ///
    /// Without this every timestamp in the trace would refer to a clip that
    /// exists only inside this function, and `docs/cli.md`'s "did the decoder
    /// stop, or the gate?" query — which reads `asr.words` against
    /// `vad.segments` — would compare two different timelines.
    nonisolated static func restoreTimings(
        _ result: ASRResult, closed: ClosedClip, seconds: Double
    ) -> ASRResult {
        func was(_ now: Double) -> Double {
            for piece in closed.pieces where now < piece.now + piece.length {
                return piece.was + max(0, now - piece.now)
            }
            guard let last = closed.pieces.last else { return now }
            return last.was + last.length
        }

        return ASRResult(
            text: result.text,
            confidence: result.confidence,
            duration: seconds,
            processingTime: result.processingTime,
            tokenTimings: result.tokenTimings.map { timings in
                timings.map {
                    TokenTiming(
                        token: $0.token,
                        tokenId: $0.tokenId,
                        startTime: was($0.startTime),
                        endTime: was($0.endTime),
                        confidence: $0.confidence
                    )
                }
            },
            performanceMetrics: result.performanceMetrics,
            ctcDetectedTerms: result.ctcDetectedTerms,
            ctcAppliedTerms: result.ctcAppliedTerms
        )
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
