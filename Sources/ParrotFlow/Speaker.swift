import AVFoundation
import FluidAudio

/// Says text one sentence at a time, so the first words play while the rest
/// are still being made. A local voice on this Mac (Kokoro or PocketTTS), or
/// `remote` for a line that has a style, with the local voice taking over any
/// sentence the remote one fails on. PocketTTS streams: a sentence arrives in
/// pieces, and they play back to back.
final class Speaker {

    enum Local: String { case kokoro, pocket }

    var voice = "af_heart"
    var speed: Float = 1.0
    var remote: ModelSpec?
    var local: Local = .kokoro
    var localVoice = PocketTtsConstants.defaultVoice

    /// A remote voice and tone for one line. Kokoro ignores both.
    struct Style: Equatable {
        var voice: String
        var tone: String?
    }
    /// Called on the main queue when the session being heard changes; nil when silent.
    var onSpeakingSession: ((String?) -> Void)?
    /// The output's loudness (RMS), on the main queue, about 45 times a second.
    var onLevel: ((Float) -> Void)?

    var isSpeaking: Bool { !scheduled.isEmpty || !ready.isEmpty || !lines.isEmpty || synthesizing }
    private(set) var speakingSession: String? {
        didSet { if speakingSession != oldValue { onSpeakingSession?(speakingSession) } }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var manager: KokoroAneManager?
    private var managerVoice = ""
    private var loading: (voice: String, task: Task<KokoroAneManager, Error>)?
    private var pocket: PocketTtsManager?
    private var pocketLoading: Task<PocketTtsManager, Error>?

    /// One spoken line: its sentences, in order, and whose it is.
    private struct Line {
        var id: Int
        var session: String
        var progress: Bool
        var style: Style?
        var sentences: [String]
    }
    private struct Chunk {
        var seq: Int
        var line: Int
        var session: String
        var progress: Bool
        var samples: [Float]
    }
    /// Lines with sentences still to make, oldest first.
    private var lines: [Line] = []
    /// Made and waiting to play, in order.
    private var ready: [Chunk] = []
    /// Handed to the player, all from one line, oldest first.
    private var scheduled: [Chunk] = []
    private var nextChunk = 0
    /// The sentence being made, so a drop that lands meanwhile still applies.
    private var inFlight: (line: Int, session: String, progress: Bool)?
    private var inFlightDropped = false
    private var lastPlayed: (session: String, ended: Date)?
    private var nextLine = 0
    /// Bumped by `stop()`, so work started before it drops its result.
    private var generation = 0
    private var synthesizing = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var engineStop: DispatchWorkItem?
    /// Between two sessions, so one does not run into the other.
    private let handover: TimeInterval = 0.5

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            DispatchQueue.main.async { self?.onLevel?(rms) }
        }
    }

    func say(_ text: String, style: Style? = nil, session: String = "", progress: Bool = false) {
        let parts = ClaudeSpeakable.sentences(text)
        guard !parts.isEmpty else { return }
        nextLine += 1
        lines.append(Line(id: nextLine, session: session, progress: progress, style: style, sentences: parts))
        if !synthesizing { synthesize(generation) }
    }

    /// Everything, now: the hotkey.
    func stop() {
        generation += 1
        lines.removeAll()
        ready.removeAll()
        synthesizing = false
        scheduled.removeAll()
        inFlight = nil
        if engine.isRunning { player.stop() }
        finishIfIdle()
    }

    /// One session's lines, queued or playing. Other sessions keep their place.
    func stop(session: String) {
        drop { $0 == session } progress: { _ in true }
    }

    /// Progress lines give way to an answer.
    func dropProgress() {
        drop { _ in true } progress: { $0 }
    }

    private func drop(session matches: (String) -> Bool, progress kind: (Bool) -> Bool) {
        lines.removeAll { matches($0.session) && kind($0.progress) }
        ready.removeAll { matches($0.session) && kind($0.progress) }
        if let making = inFlight, matches(making.session), kind(making.progress) { inFlightDropped = true }
        if let playing = scheduled.first, matches(playing.session), kind(playing.progress) {
            scheduled.removeAll()
            player.stop()
            pump()
        }
        finishIfIdle()
    }

    func waitUntilIdle() async {
        guard isSpeaking else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Loads the local voice now, so the first line is not the one that pays for it.
    func warm() async {
        switch local {
        case .kokoro: _ = try? await loadedManager()
        case .pocket: _ = try? await loadedPocket()
        }
    }

    private func loadedPocket() async throws -> PocketTtsManager {
        if let pocket { return pocket }
        if let pocketLoading { return try await pocketLoading.value }
        let voice = localVoice
        let task = Task { () throws -> PocketTtsManager in
            let started = Date()
            let made = PocketTtsManager(defaultVoice: voice)
            try await made.initialize()
            Log.write(String(format: "claude voice: PocketTTS ready in %.1fs (voice %@)",
                             Date().timeIntervalSince(started), voice))
            return made
        }
        pocketLoading = task
        do {
            let made = try await task.value
            pocket = made
            pocketLoading = nil
            return made
        } catch {
            pocketLoading = nil
            throw error
        }
    }

    private func loadedManager() async throws -> KokoroAneManager {
        if let manager, managerVoice == voice { return manager }
        if let loading, loading.voice == voice { return try await loading.task.value }
        let voice = voice
        let task = Task { () throws -> KokoroAneManager in
            let started = Date()
            let made = KokoroAneManager(variant: .english, defaultVoice: voice)
            try await made.initialize()
            Log.write(String(format: "claude voice: Kokoro ready in %.1fs (voice %@)",
                             Date().timeIntervalSince(started), voice))
            return made
        }
        loading = (voice, task)
        do {
            let made = try await task.value
            manager = made
            managerVoice = voice
            loading = nil
            return made
        } catch {
            loading = nil
            throw error
        }
    }

    /// Makes the next sentence while the one before plays.
    private func synthesize(_ started: Int) {
        synthesizing = true
        Task { @MainActor in
            while started == generation, let line = lines.first {
                let sentence = line.sentences[0]
                if lines[0].sentences.count > 1 { lines[0].sentences.removeFirst() } else { lines.removeFirst() }
                inFlight = (line.id, line.session, line.progress)
                inFlightDropped = false
                await make(sentence, style: line.style) { [weak self] samples in
                    guard let self, started == self.generation, !self.inFlightDropped, !samples.isEmpty else {
                        return false
                    }
                    self.nextChunk += 1
                    self.ready.append(Chunk(seq: self.nextChunk, line: line.id, session: line.session,
                                            progress: line.progress, samples: samples))
                    self.pump()
                    return true
                }
                guard started == generation else { return }
                inFlight = nil
            }
            guard started == generation else { return }
            synthesizing = false
            finishIfIdle()
        }
    }

    /// Hands the sentence's audio to `emit`, in one piece or, for PocketTTS,
    /// in pieces as they are made. `emit` says false once the line is dropped.
    private func make(_ sentence: String, style: Style?, emit: @MainActor ([Float]) -> Bool) async {
        if let remote, let style {
            do {
                let begun = Date()
                let samples = try await RemoteSpeech.synthesize(
                    sentence, voice: style.voice, tone: style.tone, speed: speed, config: remote
                )
                Log.write(String(format: "claude voice: %@ (%@) spoke %d chars in %.2fs",
                                 remote.name, style.voice, sentence.count, Date().timeIntervalSince(begun)))
                _ = await emit(samples)
                return
            } catch {
                Log.write("claude voice: \(remote.name) failed, the local voice takes this one — "
                    + error.localizedDescription)
            }
        }
        do {
            switch local {
            case .kokoro:
                let kokoro = try await loadedManager()
                _ = await emit(try await kokoro.synthesizeDetailed(text: sentence, voice: voice, speed: speed).samples)
            case .pocket:
                let manager = try await loadedPocket()
                let begun = Date()
                var first: TimeInterval?
                var piece: [Float] = []
                for try await frame in try await manager.synthesizeStreaming(text: sentence, voice: localVoice) {
                    piece += frame.samples
                    // About 160 ms per piece: fewer hand-offs, and the first words still start early.
                    if piece.count >= 3_840 {
                        if first == nil { first = Date().timeIntervalSince(begun) }
                        guard await emit(piece) else { return }
                        piece.removeAll(keepingCapacity: true)
                    }
                }
                if !piece.isEmpty { _ = await emit(piece) }
                Log.write(String(format: "claude voice: PocketTTS (%@) first sound %.2fs, %d chars in %.2fs",
                                 localVoice, first ?? Date().timeIntervalSince(begun), sentence.count,
                                 Date().timeIntervalSince(begun)))
            }
        } catch {
            Log.write("claude voice: \(local.rawValue) failed on \"\(sentence.prefix(60))\" — \(error.localizedDescription)")
        }
    }

    /// Starts the next line when nothing plays, after a pause when the session
    /// changes; queues the rest of the playing line back to back.
    private func pump() {
        if scheduled.isEmpty {
            guard !ready.isEmpty else { return }
            var chunk = ready.removeFirst()
            if let last = lastPlayed, last.session != chunk.session, Date().timeIntervalSince(last.ended) < 2 {
                chunk.samples = [Float](repeating: 0, count: Int(handover * 24_000)) + chunk.samples
            }
            schedule(chunk)
        }
        while let next = ready.first, next.line == scheduled.last?.line {
            schedule(ready.removeFirst())
        }
    }

    private func schedule(_ chunk: Chunk) {
        scheduled.append(chunk)
        speakingSession = chunk.session
        let started = generation
        play(chunk.samples) { [weak self] in
            guard let self, started == self.generation, self.scheduled.first?.seq == chunk.seq else { return }
            self.scheduled.removeFirst()
            if self.scheduled.isEmpty { self.lastPlayed = (chunk.session, Date()) }
            self.pump()
            self.finishIfIdle()
        }
    }

    private func play(_ samples: [Float], done: @escaping () -> Void) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return done() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        engineStop?.cancel()
        if !engine.isRunning {
            do { try engine.start() } catch {
                Log.write("claude voice: audio output did not start — \(error.localizedDescription)")
                return done()
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { done() }
        }
        if !player.isPlaying { player.play() }
    }

    private func finishIfIdle() {
        guard !isSpeaking else { return }
        speakingSession = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        // Idle output keeps the audio device awake, so let it go after a pause.
        let stopping = DispatchWorkItem { [weak self] in
            guard let self, !self.isSpeaking else { return }
            self.player.stop()
            self.engine.stop()
        }
        engineStop = stopping
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: stopping)
    }
}
