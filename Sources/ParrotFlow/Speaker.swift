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
    private(set) var isSpeaking = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var manager: KokoroAneManager?
    private var managerVoice = ""
    private var loading: (voice: String, task: Task<KokoroAneManager, Error>)?
    private var queue: [(sentence: String, style: Style?)] = []
    /// Bumped by `stop()`, so work started before it drops its result.
    private var generation = 0
    private var pendingBuffers = 0
    private var synthesizing = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var engineStop: DispatchWorkItem?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func say(_ text: String, style: Style? = nil) {
        let parts = ClaudeSpeakable.sentences(text)
        guard !parts.isEmpty else { return }
        queue.append(contentsOf: parts.map { ($0, style) })
        isSpeaking = true
        if !synthesizing { run(generation) }
    }

    func stop() {
        generation += 1
        queue.removeAll()
        pendingBuffers = 0
        synthesizing = false
        if engine.isRunning { player.stop() }
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

    private func run(_ started: Int) {
        synthesizing = true
        Task { @MainActor in
            while started == generation, !queue.isEmpty {
                let (sentence, style) = queue.removeFirst()
                if let remote, let style {
                    do {
                        let begun = Date()
                        let samples = try await RemoteSpeech.synthesize(
                            sentence, voice: style.voice, tone: style.tone, speed: speed, config: remote
                        )
                        Log.write(String(format: "claude voice: %@ (%@) spoke %d chars in %.2fs",
                                         remote.name, style.voice, sentence.count, Date().timeIntervalSince(begun)))
                        guard started == generation else { return }
                        play(samples, generation: started)
                        continue
                    } catch {
                        Log.write("claude voice: \(remote.name) failed, Kokoro takes this one — \(error.localizedDescription)")
                    }
                }
                do {
                    let kokoro = try await loadedManager()
                    let result = try await kokoro.synthesizeDetailed(
                        text: sentence, voice: voice, speed: speed
                    )
                    guard started == generation else { return }
                    play(result.samples, generation: started)
                } catch {
                    Log.write("claude voice: Kokoro failed on \"\(sentence.prefix(60))\" — \(error.localizedDescription)")
                }
            }
            guard started == generation else { return }
            synthesizing = false
            finishIfIdle()
        }
    }

    private func play(_ samples: [Float], generation started: Int) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        engineStop?.cancel()
        if !engine.isRunning {
            do { try engine.start() } catch {
                Log.write("claude voice: audio output did not start — \(error.localizedDescription)")
                return
            }
        }
        pendingBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self, started == self.generation else { return }
                self.pendingBuffers -= 1
                self.finishIfIdle()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func finishIfIdle() {
        guard pendingBuffers == 0, !synthesizing, queue.isEmpty else { return }
        isSpeaking = false
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
