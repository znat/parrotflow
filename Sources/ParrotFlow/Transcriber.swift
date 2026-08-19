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

    /// The download in flight, if any. Actor isolation stops a torn read or
    /// write of `models`/`vad`, but not two callers both finding them nil on
    /// either side of the same `await` — an eager warm-up at launch racing
    /// the first dictation's own call, say. A caller that arrives mid-load
    /// joins this task instead of starting a second download.
    private var loadingModels: Task<AsrModels, Error>?
    private var loadingVad: Task<VadManager?, Error>?

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

    /// Downloads and loads models if needed. Safe to call repeatedly, and
    /// safe to call concurrently: overlapping callers converge on the same
    /// in-progress load instead of racing separate downloads.
    func prepare(config: Config) async throws {
        if models == nil {
            models = try await loadModels()
        }

        if config.audio.speechGate, vad == nil {
            vad = try await loadVad()
        }

        setStatus(.ready)
    }

    private func loadModels() async throws -> AsrModels {
        if let loadingModels { return try await loadingModels.value }
        setStatus(.downloading("speech model"))
        let task = Task<AsrModels, Error> {
            try await AsrModels.downloadAndLoad(
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.reportDownload("speech model", progress) }
                }
            )
        }
        loadingModels = task
        defer { loadingModels = nil }
        return try await task.value
    }

    private func loadVad() async throws -> VadManager? {
        if let loadingVad { return try await loadingVad.value }
        setStatus(.downloading("voice detector"))
        let task = Task<VadManager?, Error> {
            let vad = try? await VadManager(config: .default)
            if vad == nil { Log.write("speech gate: VAD unavailable; transcribing everything") }
            return vad
        }
        loadingVad = task
        defer { loadingVad = nil }
        return try await task.value
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

    /// What the decoder made of one clip, for a surface that draws it.
    struct Decode: Sendable {
        /// The decoder's own words with their scores, before any stage
        /// rewrote them.
        let words: [Trace.Word]
        /// Its one score for the whole utterance. See `Confidence.overall`.
        let confidence: Float
        /// The terms the vocabulary pass wrote into the text.
        let vocabulary: [String]
    }

    /// Transcribes a finished recording. Returns the cleaned-up text.
    ///
    /// `heard` is handed what the decoder made of the clip — see `Decode`.
    /// Handed over rather than read back off `Trace` for the same reason
    /// the scope values below are: the collector is only bound when somebody
    /// asked for a trace, and a feature that worked on the runs you are watching
    /// and stopped on the runs you are not would be worse than no feature.
    func transcribe(
        url: URL, config: Config, app: Pipeline.App? = nil,
        progress: (@Sendable (String) -> Void)? = nil,
        heard: (@Sendable (Decode) -> Void)? = nil
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
            if Self.lastWordEnd(retried) > Self.lastWordEnd(result), Self.extends(result, by: retried) {
                Log.write(String(
                    format: "decoder stopped %.2fs before the speech did; "
                        + "closed %d long pause(s) and recovered to %.2fs",
                    Self.lastSpeechEnd(gated) - Self.lastWordEnd(result),
                    closed.pauses, Self.lastWordEnd(retried)
                ))
                result = retried
            } else if Self.lastWordEnd(retried) > Self.lastWordEnd(result) {
                Log.write(String(
                    format: "closed %d long pause(s) and reached %.2fs, but the retry "
                        + "rewrote text the first pass had already decoded; keeping the first pass",
                    closed.pauses, Self.lastWordEnd(retried)
                ))
            }
        }

        // A clip can decode to nothing at all. The gate hears speech, the
        // decoder commits no token, and the dictation is lost with no sign of
        // why. Measured on three clips of "I don't know" said into Slack:
        // 0.85s, 1.11s and 1.87s of speech at normal level, all three empty,
        // all three still empty when replayed from the file.
        //
        // It is not level and it is not duration. Decoding those same clips
        // with silence added at both ends returned the words every time, and a
        // sweep of the pad — 0, 50, 100, 200, 300, 400, 500, 800ms — recovered
        // them at every step but 200 and 300, and there on one clip only. A
        // rule that is not monotonic in the pad is not a threshold; it is
        // where the encoder's frames land against the speech. Silence either
        // side moves them.
        //
        // Any text beats none, so a non-empty retry is taken as it stands.
        // There is nothing to protect: the first pass decoded nothing. Over
        // the archive this recovered 30 of the 56 clips that had been lost
        // this way, and invented nothing on the other 26.
        //
        // Separate from the retry above, which needs words to measure a
        // dropped tail against and so cannot reach this case at all:
        // `droppedTail` is false on an empty decode by definition.
        if let gated, Self.decodedNothing(result, gate: gated) {
            let speech = Self.speechSeconds(gated)
            if let retried = try await decodePadded(gated, asr: asr),
                !retried.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.write(String(
                    format: "decoder returned nothing for %.2fs of speech; "
                        + "%.0fms of silence either side recovered it",
                    speech, Self.silenceRetryPad * 1000
                ))
                result = retried
            } else {
                Log.write(String(
                    format: "decoder returned nothing for %.2fs of speech, "
                        + "and the padded retry returned nothing either",
                    speech
                ))
            }
        }
        Trace.current?.recordASR(result, model: Repo.parakeetV3.rawValue)

        // Before the pipeline, because this is the last point where the words
        // still line up with the audio they came from. Every text stage after
        // it — numbers especially — rewrites words the token timings index.
        var text = result.text
        var vocabularyCount = 0
        var vocabularyChanges = ""
        // What the pass proposed and did not write, with the text it measured
        // those positions against. Handed to the pipeline as a value rather
        // than published as a variable: a range is not a string, and the
        // prototype's JSON hand-off is where four of its bugs lived (F5, F9).
        var findings: Vocabulary.Outcome?
        if Vocabulary.wanted(config) {
            do {
                try await Vocabulary.shared.prepare(config: config) { [weak self] label in
                    Task { await self?.setStatus(.downloading(label)) }
                }
                // The gate has already read the clip, so re-reading it would
                // be a second decode of the same file for the same array.
                let gateSamples = gated?.decodable == true ? gated?.samples : nil
                if let samples = gateSamples ?? Self.samples(at: url) {
                    Self.logVocabularySamples(
                        samples, from: gateSamples == nil ? .file : .gate
                    )
                    let outcome = await Vocabulary.shared.apply(
                        to: text, samples: samples,
                        tokenTimings: result.tokenTimings ?? [], config: config
                    )
                    text = outcome.text
                    vocabularyCount = outcome.count
                    vocabularyChanges = outcome.changes
                    findings = outcome
                } else {
                    // The pass is configured and did nothing, which used to
                    // look exactly like the pass finding no names. Say which.
                    Log.write(
                        "vocabulary samples: none — no 16 kHz mono samples for"
                            + " \(url.lastPathComponent); left as decoded"
                    )
                }
            } catch {
                Log.write("vocabulary: \(error.localizedDescription); left as decoded")
            }
            setStatus(.ready)
        }

        // After the vocabulary pass rather than before it, though the words
        // handed over are still the decoder's own. Whoever reads a score needs
        // to know which words the pass wrote: those carry the score of the
        // decode they replaced, which is low by definition — that is why the
        // pass fired — and warning about a name the app has already fixed is
        // warning about the fix. See `Confidence.warning`.
        if let heard {
            heard(Decode(
                words: Trace.words(from: result.tokenTimings ?? []),
                confidence: result.confidence,
                vocabulary: findings?.proposals.filter(\.applied).map(\.term) ?? []
            ))
        }

        // The same numbers the trace records, handed to the pipeline as well.
        //
        // Not read back off `Trace`, deliberately. The collector is bound only
        // when somebody asked for a trace — `Trace.current` is nil the rest of
        // the time — and a condition reading `asr.confidence` must not work on
        // the runs you are watching and quietly stop on the runs you are not.
        // So the trace consumes these; it does not own them.
        return await Self.applyReplacements(
            to: text, config: config, app: app,
            seed: Scope(values: [
                "asr.model": .string(Repo.parakeetV3.rawValue),
                "asr.confidence": .double(Double(result.confidence)),
                "asr.duration": .double(result.duration),
                "asr.processing": .double(result.processingTime),
                "asr.words": .int(result.tokenTimings?.count ?? 0),
                // What the vocabulary pass wrote, for a stage that judges the
                // substitutions rather than making them. Seeded even when it
                // did nothing, so `vocabulary.count > 0` is a condition a
                // pipeline can read rather than an error about a missing path.
                "vocabulary.count": .int(vocabularyCount),
                "vocabulary.changes": .string(vocabularyChanges),
            ]),
            findings: findings,
            progress: progress
        )
    }

    /// Decodes the clip again with silence at both ends, on a decoder state of
    /// its own, and puts the timings back on the recording's clock.
    ///
    /// A fresh `TdtDecoderState` per pass: the state is per-clip, and handing
    /// the first pass's state to the second would decode the padded copy as a
    /// continuation of the clip it is a copy of.
    private func decodePadded(_ gate: SpeechGate, asr: AsrManager) async throws -> ASRResult? {
        guard let padded = Self.paddedWithSilence(gate) else { return nil }
        var state = await TdtDecoderState.make(decoderLayers: asr.decoderLayerCount)
        let raw = try await asr.transcribe(padded, decoderState: &state)
        return Self.unpadTimings(raw, by: Self.silenceRetryPad, seconds: gate.seconds)
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
    ///
    /// A clip it cannot read fails open too. Reading it used to throw here and
    /// lose the dictation; the decoder is handed the same URL a line later and
    /// reports the real failure itself, so there is nothing for this to add.
    private func runSpeechGate(url: URL) async throws -> SpeechGate? {
        guard let vad else { return nil }

        guard let clip = Self.read(url) else { return nil }
        let samples = clip.samples
        guard !samples.isEmpty else {
            return SpeechGate(samples: samples, segments: [], decodable: clip.is16kMono)
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
            decodable: clip.is16kMono
        )
    }

    // MARK: - The seam the vocabulary pass sits on

    /// Which of the two readers produced the samples handed to `Vocabulary`.
    ///
    /// There is one call site and two branches, and for a clip the recorder
    /// wrote they must produce the same array: both read the same file at its
    /// own `processingFormat`. Naming the branch in the log is what makes that
    /// checkable instead of assumed.
    enum SampleSource: String {
        /// Already read by `runSpeechGate`.
        case gate
        /// Read here, because the gate is off or could not use what it read.
        case file
    }

    /// One line saying exactly what the vocabulary pass was given.
    ///
    /// A dictation and a replay of its archived wav scored the same term ~12
    /// nats apart (finding F12), and nothing on disk could say whether the two
    /// runs even saw the same audio. This line answers that with a grep. One
    /// helper for both branches on purpose: two format strings would drift and
    /// the comparison would stop being mechanical.
    ///
    /// The run's own origin comes from the trace, which already records `live`
    /// or `cli` per dictation. `unknown` means no collector was bound — a
    /// command that does not trace, not a third audio path.
    nonisolated static func logVocabularySamples(_ samples: [Float], from source: SampleSource) {
        let seconds = Double(samples.count) / sampleRate
        let head = String(
            format: "vocabulary samples: %d samples, %.2fs, checksum %08x",
            samples.count, seconds, checksum(samples)
        )
        Log.write("\(head) (\(Trace.current?.source.rawValue ?? "unknown"), \(source.rawValue))")
    }

    /// FNV-1a over the raw bits of every sample.
    ///
    /// Not a digest anyone should trust for anything else. It has one job: to
    /// change when a single sample changes, so two runs can be compared by
    /// eye. Hashing the bit pattern rather than the value keeps `-0.0` and
    /// `0.0` distinct, which is what "the same array" has to mean here.
    nonisolated static func checksum(_ samples: [Float]) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for sample in samples {
            var bits = sample.bitPattern
            for _ in 0..<4 {
                hash = (hash ^ (bits & 0xFF)) &* 16_777_619
                bits >>= 8
            }
        }
        return hash
    }

    /// The one reader. Everything that needs the clip as numbers goes through
    /// here — the speech gate, and the vocabulary pass when the gate is off.
    ///
    /// It used to be two readers with the same body written twice, and they
    /// only agreed by luck. A live dictation and a replay of its archived wav
    /// scored the same term far apart (finding F12), and the first thing that
    /// had to be ruled out was whether the two runs were even looking at the
    /// same samples. Two copies of a file read cannot be ruled out; one can.
    ///
    /// Nil rather than throwing: a name left misheard is worth less than a
    /// lost dictation.
    ///
    /// - Parameter require16kMono: nil for any other format, decided from the
    ///   header before a buffer is allocated. A caller that cannot use the
    ///   samples should not pay to read an hour of audio to find that out.
    static func read(
        _ url: URL, require16kMono: Bool = false
    ) -> (samples: [Float], is16kMono: Bool)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let is16kMono = format.sampleRate == sampleRate && format.channelCount == 1
        guard is16kMono || !require16kMono else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ),
            (try? file.read(into: buffer)) != nil,
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        return (
            Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            is16kMono
        )
    }

    /// The clip as 16 kHz mono samples, for the vocabulary pass when the
    /// speech gate is off and has not already read them.
    ///
    /// Nil for anything else: the decoder reaches those clips through the URL,
    /// which resamples, and this does not. Handing the pass a differently
    /// sampled array would be the second audio path all over again.
    static func samples(at url: URL) -> [Float]? {
        read(url, require16kMono: true)?.samples
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

    /// True when the retry says everything the first pass said, in the same
    /// order, before it says anything new.
    ///
    /// Reaching further into the clip is not on its own a reason to take the
    /// retry. It decodes the *whole* clip, not just the tail, and closing the
    /// pauses moves every window boundary after the first pause — so its
    /// version of the opening is a different decode of audio the first pass
    /// may already have got right. Swapping wholesale on the strength of a
    /// later ending would trade a recovered tail for a silently rewritten
    /// beginning, which is a worse bug than the one being fixed: nobody
    /// re-reads the part that was already correct.
    ///
    /// Prefix rather than equality, because what makes the retry worth having
    /// is precisely the words it adds at the end. Compared on letters and
    /// digits alone so that a different token split, a comma, or a capital at
    /// a moved window boundary is not read as rewritten speech.
    nonisolated static func extends(_ result: ASRResult, by retried: ASRResult) -> Bool {
        let first = comparable(result.text)
        guard !first.isEmpty else { return false }
        return comparable(retried.text).hasPrefix(first)
    }

    private nonisolated static func comparable(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// True when the decoder stopped well before the speech did — the symptom
    /// this whole retry exists for, and the only thing that triggers it.
    nonisolated static func droppedTail(_ result: ASRResult, gate: SpeechGate) -> Bool {
        guard !gate.segments.isEmpty, result.tokenTimings?.isEmpty == false else { return false }
        return lastSpeechEnd(gate) - lastWordEnd(result) > droppedTailSeconds
    }

    /// How much silence the empty-decode retry puts either side of the clip.
    ///
    /// Picked from the middle of a plateau rather than an edge. On the three
    /// clips that prompted this, 400, 500 and 800ms all recovered the words;
    /// 50 and 100ms did too, but 200 and 300ms did not, on one of them. The
    /// safe reading of a gap like that is to sit well clear of it.
    static let silenceRetryPad = 0.5

    nonisolated static func speechSeconds(_ gate: SpeechGate) -> Double {
        gate.segments.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// True when the gate heard speech and the decoder wrote nothing at all.
    ///
    /// The text, not the timings: a decode with no words is the thing being
    /// caught, and whether it also carried an empty timing array is a detail
    /// of the decoder rather than the symptom.
    nonisolated static func decodedNothing(_ result: ASRResult, gate: SpeechGate) -> Bool {
        guard !gate.segments.isEmpty else { return false }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The clip with `silenceRetryPad` of silence at each end, or nil when the
    /// retry cannot help.
    ///
    /// Nil for a clip whose samples cannot go to the decoder directly, and nil
    /// when the padding would push it past a single decoder window. Past that
    /// the batch path chunks, and the seam it opens is the bug the first pass
    /// already works around — so a retry that created one would be trading
    /// this failure for that one.
    nonisolated static func paddedWithSilence(_ gate: SpeechGate) -> [Float]? {
        guard gate.decodable, !gate.samples.isEmpty else { return nil }
        let pad = Int((silenceRetryPad * sampleRate).rounded())
        guard gate.samples.count + 2 * pad <= ASRConstants.maxModelSamples else { return nil }
        return [Float](repeating: 0, count: pad) + gate.samples
            + [Float](repeating: 0, count: pad)
    }

    /// Takes the padding back off the word timings, so they refer to the
    /// recording and not to the padded copy this pass decoded. Same job as
    /// `restoreTimings`, one subtraction rather than a piece map.
    nonisolated static func unpadTimings(
        _ result: ASRResult, by pad: Double, seconds: Double
    ) -> ASRResult {
        ASRResult(
            text: result.text,
            confidence: result.confidence,
            duration: seconds,
            processingTime: result.processingTime,
            tokenTimings: result.tokenTimings.map { timings in
                timings.map {
                    TokenTiming(
                        token: $0.token,
                        tokenId: $0.tokenId,
                        startTime: min(max($0.startTime - pad, 0), seconds),
                        endTime: min(max($0.endTime - pad, 0), seconds),
                        confidence: $0.confidence
                    )
                }
            },
            performanceMetrics: result.performanceMetrics,
            ctcDetectedTerms: result.ctcDetectedTerms,
            ctcAppliedTerms: result.ctcAppliedTerms
        )
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
        seed: Scope = Scope(), findings: Vocabulary.Outcome? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        await Replacements.apply(
            to: text, config: config, app: app, seed: seed,
            findings: findings, progress: progress
        )
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
