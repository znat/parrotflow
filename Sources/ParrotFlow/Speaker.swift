import AVFoundation
import FluidAudio

/// Says text one sentence at a time, so the first words play while the rest
/// are still being made. Kokoro on this Mac, or `remote` when it is set, with
/// Kokoro taking over any sentence the remote voice fails on.
final class Speaker {

    var voice = "af_heart"
    var speed: Float = 1.0
    var remote: ModelSpec?

    /// A remote voice and tone for one line. Kokoro ignores both.
    struct Style: Equatable {
        var voice: String
        var tone: String?
    }
    /// Called on the main queue when the session being heard changes; nil when silent.
    var onSpeakingSession: ((String?) -> Void)?

    var isSpeaking: Bool { current != nil || !ready.isEmpty || !lines.isEmpty || synthesizing }
    private(set) var speakingSession: String? {
        didSet { if speakingSession != oldValue { onSpeakingSession?(speakingSession) } }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var manager: KokoroAneManager?
    private var managerVoice = ""
    private var loading: (voice: String, task: Task<KokoroAneManager, Error>)?

    /// One spoken line: its sentences, in order, and whose it is.
    private struct Line {
        var id: Int
        var session: String
        var progress: Bool
        var style: Style?
        var sentences: [String]
    }
    private struct Chunk {
        var line: Int
        var session: String
        var progress: Bool
        var samples: [Float]
    }
    /// Lines with sentences still to make, oldest first.
    private var lines: [Line] = []
    /// Made and waiting to play, in order.
    private var ready: [Chunk] = []
    private var current: Chunk?
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
        current = nil
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
        if let playing = current, matches(playing.session), kind(playing.progress) {
            current = nil
            player.stop()
            pump()
        }
        finishIfIdle()
    }

    func waitUntilIdle() async {
        guard isSpeaking else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Loads Kokoro now, so the first line is not the one that pays for it.
    func warm() async {
        _ = try? await loadedManager()
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
                let samples = await make(sentence, style: line.style)
                guard started == generation else { return }
                let dropped = inFlightDropped
                inFlight = nil
                guard !dropped, let samples, !samples.isEmpty else { continue }
                ready.append(Chunk(line: line.id, session: line.session, progress: line.progress, samples: samples))
                if current == nil { pump() }
            }
            guard started == generation else { return }
            synthesizing = false
            finishIfIdle()
        }
    }

    private func make(_ sentence: String, style: Style?) async -> [Float]? {
        if let remote, let style {
            do {
                let begun = Date()
                let samples = try await RemoteSpeech.synthesize(
                    sentence, voice: style.voice, tone: style.tone, speed: speed, config: remote
                )
                Log.write(String(format: "claude voice: %@ (%@) spoke %d chars in %.2fs",
                                 remote.name, style.voice, sentence.count, Date().timeIntervalSince(begun)))
                return samples
            } catch {
                Log.write("claude voice: \(remote.name) failed, Kokoro takes this one — \(error.localizedDescription)")
            }
        }
        do {
            let kokoro = try await loadedManager()
            return try await kokoro.synthesizeDetailed(text: sentence, voice: voice, speed: speed).samples
        } catch {
            Log.write("claude voice: Kokoro failed on \"\(sentence.prefix(60))\" — \(error.localizedDescription)")
            return nil
        }
    }

    /// Plays the next ready sentence, after a pause when the session changes.
    private func pump() {
        guard current == nil, !ready.isEmpty else { return }
        var chunk = ready.removeFirst()
        if let last = lastPlayed, last.session != chunk.session, Date().timeIntervalSince(last.ended) < 2 {
            chunk.samples = [Float](repeating: 0, count: Int(handover * 24_000)) + chunk.samples
        }
        current = chunk
        speakingSession = chunk.session
        let started = generation
        play(chunk.samples) { [weak self] in
            guard let self, started == self.generation, self.current?.line == chunk.line else { return }
            self.lastPlayed = (chunk.session, Date())
            self.current = nil
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
