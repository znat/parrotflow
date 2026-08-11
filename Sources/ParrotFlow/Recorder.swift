import AVFoundation
import CoreAudio
import Foundation

/// Captures the default input device and writes 16 kHz mono PCM WAV files —
/// the format Parakeet expects, so the transcription step can read them as-is.
final class Recorder {

    struct Recording {
        let url: URL
        let duration: TimeInterval
        /// Root-mean-square of the whole clip, 0...1. Says whether anything was
        /// heard, which the duration cannot: a lost take and a good one are the
        /// same length. See `silenceFloor`.
        let rms: Float
    }

    /// What the engine is bound to: which input device, and the format that
    /// device is running at.
    ///
    /// Both halves matter, and only the first one used to be checked. A device
    /// can keep its identity and change its format — AirPods do it a second or
    /// two after they become the input, while the Bluetooth link settles — and
    /// an identity test alone reads that as "nothing moved". It is the change
    /// that costs the most: `AVAudioConverter` built from the old format
    /// returns `.error` for every buffer at the new one, `process` drops them
    /// all, and the clip is silence with no error anywhere. See #95.
    struct InputBinding: Equatable {
        let device: AudioDeviceID
        let sampleRate: Double
        let channels: UInt32

        var described: String {
            "device \(device) at \(Int(sampleRate)) Hz, \(channels) ch"
        }

        /// What CoreAudio would hand the engine right now. Nil when the machine
        /// has no input device at all.
        ///
        /// The format comes from the input stream's virtual format, which is
        /// the same fact `AVAudioEngine`'s input node reports — measured equal
        /// on every input device on this machine, including an aggregate one.
        /// That equality is what lets `formatProblem` compare the two and call
        /// a difference stale rather than a unit mismatch.
        static func system() -> InputBinding? {
            guard let device = Recorder.defaultInputDeviceID else { return nil }
            guard let format = inputStreamFormat(of: device) else {
                // A device with no input stream to ask. Zeroes still compare,
                // which is all the change detection needs, and `formatProblem`
                // treats a rate of zero as nothing to say.
                return InputBinding(device: device, sampleRate: 0, channels: 0)
            }
            return InputBinding(
                device: device,
                sampleRate: format.mSampleRate,
                channels: format.mChannelsPerFrame
            )
        }

        private static func inputStreamFormat(
            of device: AudioDeviceID
        ) -> AudioStreamBasicDescription? {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                device, &streamsAddress, 0, nil, &size
            ) == noErr, size > 0 else { return nil }

            var streams = [AudioStreamID](
                repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size
            )
            guard AudioObjectGetPropertyData(
                device, &streamsAddress, 0, nil, &size, &streams
            ) == noErr, let first = streams.first else { return nil }

            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(
                first, &formatAddress, 0, nil, &formatSize, &format
            ) == noErr else { return nil }
            return format
        }
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case unsupportedFormat
        case converterUnavailable
        case inputStillConnecting

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device is available."
            case .unsupportedFormat:
                return "Could not build a 16 kHz mono format."
            case .converterUnavailable:
                return "Could not convert the microphone's format to 16 kHz mono."
            case .inputStillConnecting:
                return "The microphone is still connecting — press again in a moment."
            }
        }
    }

    /// Below this, a clip is silence rather than a quiet room.
    ///
    /// -60 dBFS. The lost takes in #95 measured 2.9 to 4.3 RMS in 16-bit units,
    /// which is 0.0001 here; the working takes beside them measured 682 to 917,
    /// or 0.021. A live microphone in a quiet room sits around 0.003. So the
    /// floor is twenty times under a quiet room and ten times over true
    /// silence: it cannot fire on speech and cannot miss a dead clip.
    static let silenceFloor: Float = 0.001

    /// How much lost audio a clip can carry and still be worth transcribing.
    ///
    /// Neither zero nor unbounded, and both ends have a cost.
    ///
    /// Not zero, because a device change ends a recording through
    /// `onUnexpectedStop`, and the tap can deliver a buffer in the new format
    /// before that hop reaches the main queue. One 4096-frame buffer is
    /// 4096/rate seconds however the conversion goes: 85 ms at 48 kHz, 171 ms
    /// at 24 kHz, 256 ms at 16 kHz. Refusing a whole dictation over that would
    /// throw away every word of a take whose words all arrived, on every
    /// headset that disconnects itself.
    ///
    /// Not unbounded, because past a certain hole the transcript is a sentence
    /// with words missing and nothing to say which — the failure this file is
    /// about, delivered as text instead of as nothing. 0.3s covers one buffer
    /// at every rate a microphone runs at, and two at 48 kHz.
    ///
    /// A loss under it is still said out loud. The tolerance decides whether
    /// the clip is transcribed, never whether the person is told.
    static let droppedAudioTolerance: TimeInterval = 0.3

    /// How long a hotkey press waits for an engine that is still being built.
    ///
    /// A settled device rebuilds in about 0.1s, so this covers every rebuild
    /// worth waiting for. Past it the device is still negotiating — Bluetooth
    /// took 4s twice and 30s once on 2026-08-10 — and the honest answer is a
    /// message you can act on, not an app that stops answering the hotkey.
    private static let rebuildWaitSeconds: Double = 1.5

    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// How many engines this recorder has been through. Read by
    /// `--audio-recovery` to see whether a device change was acted on, from a
    /// different thread than the one that counts them.
    var rebuilds: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rebuildCount
    }
    private var rebuildCount = 0

    /// 0...1, already smoothed — drive a meter with it. Called on the main queue.
    var onLevel: ((Float) -> Void)?
    /// Fired when recording stops on its own (e.g. the audio device changed).
    var onUnexpectedStop: ((Error?) -> Void)?
    /// What was wrong with the last recording, or nil if nothing was.
    ///
    /// A dictation that captures nothing is worse than one that fails loudly:
    /// the sentence is gone either way, and only one of them tells you to say
    /// it again. Called on the main queue after every `stop`.
    var onCaptureProblem: ((String?) -> Void)?

    /// What the system would hand us right now.
    ///
    /// A property rather than a direct call so `--audio-recovery` can move the
    /// input under the recorder without moving the machine's audio settings.
    /// Nothing in the app replaces it.
    var currentInput: () -> InputBinding? = InputBinding.system

    /// Recreated when the audio device changes — an engine holds on to the
    /// device it was prepared against. Guarded by `stateLock`.
    private var engine = AVAudioEngine()
    /// The binding the engine was last prepared against — what it will actually
    /// record through, which is not always what the system would hand us today.
    /// See `reacquireIfInputMoved` and `start`. Guarded by `stateLock`.
    private var bound: InputBinding?
    /// True while an engine is being built on `engineQueue`. Guarded by
    /// `stateLock`.
    private var rebuilding = false
    private let stateLock = NSLock()

    /// A format disagreement a rebuild has already been spent on. Main thread
    /// only — `start` is the only thing that reads or writes it.
    private var acceptedFormatMismatch: String?

    /// Builds engines off the main thread.
    ///
    /// Instantiating an input node opens the device. On Bluetooth that has been
    /// measured at 4s twice and once at 30s — the gaps between "rebuilding the
    /// capture engine" and "capture engine rebuilt" in the log of 2026-08-10,
    /// 17:00:23 to 17:01:05. Those were main-thread seconds: the hotkey was not
    /// delivered, no recording started, and not one line was written. The app
    /// looked dead, and quitting it was the only way out.
    private let engineQueue = DispatchQueue(label: "com.parrotflow.recorder.engine")
    /// Empty unless a rebuild is under way. `start` waits on it, briefly.
    private let rebuildGroup = DispatchGroup()

    private let writeLock = NSLock()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var currentURL: URL?
    private var smoothedLevel: Float = 0
    /// What reached disk, what did not, and why — all guarded by `writeLock`, so
    /// `stop` reads totals that match the file it is about to hand back.
    ///
    /// `capturedFrames` counts what reached disk, not what reached the
    /// converter. The two are the same until something fails, and on that day
    /// the difference is a clip that reports a healthy level and holds less
    /// audio than was spoken. `droppedFrames` is that difference, in frames at
    /// the output rate, so `stop` can say how many seconds went missing rather
    /// than how many buffers.
    private var capturedFrames: Int64 = 0
    private var capturedEnergy: Double = 0
    private var droppedFrames: Int64 = 0
    private var refusedBuffers: Int = 0
    private var failedWrites: Int = 0

    init() {
        observeConfigurationChanges(on: engine)
    }

    private func observeConfigurationChanges(on engine: AVAudioEngine) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    /// Instantiates the input node and allocates the engine's resources ahead of
    /// time, so the first `start()` doesn't swallow the first ~150 ms of speech.
    ///
    /// This does not open the input stream — the orange mic indicator stays off
    /// until `start()` actually runs the engine.
    func warmUp() {
        let engine = currentEngine()
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
        stateLock.lock()
        bound = currentInput()
        stateLock.unlock()
    }

    // MARK: - Start

    @discardableResult
    func start(config: Config) throws -> URL {
        guard !isRecording else { return currentURL! }

        // The engine keeps the device *and the format* it was prepared against.
        // If either has moved since — AirPods in, AirPods back out, or AirPods
        // simply settling their link — it is holding a format the hardware has
        // left. The notification that announces the change is not enough by
        // itself, so the binding is checked here too, at the one moment it has
        // to be right.
        reacquireIfInputMoved()
        try waitForRebuild()

        var engine = currentEngine()
        var inputFormat = engine.inputNode.outputFormat(forBus: 0)

        if let problem = Self.formatProblem(inputFormat, against: currentInput()),
           problem != acceptedFormatMismatch {
            // A second chance rather than an error, for both shapes of the
            // problem. An empty format means the engine is pointing at nothing;
            // a format that disagrees with the device means it is pointing at
            // what the device used to be. A fresh engine fixes both, and the
            // alternative is telling someone their microphone is missing at the
            // exact moment they are talking into it.
            Log.write("\(problem); rebuilding the capture engine")
            rebuildEngine(because: problem)
            try waitForRebuild()
            engine = currentEngine()
            inputFormat = engine.inputNode.outputFormat(forBus: 0)

            let remaining = Self.formatProblem(inputFormat, against: currentInput())
            // Remembered whether it cleared or not. A device whose engine and
            // stream never agree would otherwise buy a rebuild on every single
            // press, which is a second bug wearing the first one's clothes.
            acceptedFormatMismatch = remaining
            if let remaining {
                // Fail open. A recording that may be wrong beats refusing to
                // record — but said out loud, because the whole point of #95 is
                // that this used to be the silent path.
                Log.write("after the rebuild, \(remaining) — recording anyway")
                report("The microphone is not answering as expected.")
            }
        }
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        let inputNode = engine.inputNode

        let url = try openCapture(inputFormat: inputFormat, config: config)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            teardown()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        beginRecording()
        return url
    }

    /// Builds what the tap writes through — the converter to 16 kHz mono and the
    /// file on disk.
    ///
    /// Split out of `start` so `--audio-recovery` can push buffers through the
    /// exact conversion the tap uses without opening the microphone. Nothing in
    /// the app calls it directly.
    ///
    /// - Parameter markRecording: whether to enter the recording state here.
    ///   `start` leaves it false and calls `beginRecording` only once the engine
    ///   is running. `prepare()` posts a configuration change of its own, and a
    ///   recorder that already calls itself recording answers that by stopping
    ///   the take it is halfway through starting.
    @discardableResult
    func openCapture(
        inputFormat: AVAudioFormat, config: Config, markRecording: Bool = false
    ) throws -> URL {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.audio.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.unsupportedFormat
        }
        targetFormat = target

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter

        let url = try makeOutputURL(config: config)
        // Float32 in memory, 16-bit PCM on disk: small files, no quality loss
        // that matters at 16 kHz speech.
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: config.audio.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        audioFile = file
        currentURL = url

        writeLock.lock()
        capturedFrames = 0
        capturedEnergy = 0
        droppedFrames = 0
        refusedBuffers = 0
        failedWrites = 0
        writeLock.unlock()

        if markRecording { beginRecording() }
        return url
    }

    private func beginRecording() {
        startedAt = Date()
        setRecording(true)
    }

    // MARK: - Stop

    /// Returns nil if nothing was recording, if the clip was shorter than
    /// `min_duration_seconds`, if nothing was captured at all, or if part of
    /// what was captured never reached the file.
    ///
    /// The last two say so through `onCaptureProblem`, because they are the
    /// ones where a sentence was spoken and lost. Only a clip whose audio is
    /// whole is handed back to be transcribed: half a sentence typed into
    /// somebody's editor, with nothing to say which half is missing, is the
    /// failure this is here to stop, not a lesser version of it.
    @discardableResult
    func stop(config: Config) -> Recording? {
        guard isRecording else { return nil }
        setRecording(false)

        let engine = currentEngine()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let url = currentURL

        writeLock.lock()
        let frames = capturedFrames
        let energy = capturedEnergy
        let refused = refusedBuffers
        let failed = failedWrites
        let dropped = droppedFrames
        writeLock.unlock()

        teardown()

        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }

        // The device may have moved while this recording was running — that is
        // one of the things that ends one early. Re-acquire now rather than at
        // the next press, so the press finds an engine that is already right.
        reacquireIfInputMoved()

        guard let url else { return nil }
        guard duration >= config.audio.minDurationSeconds else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        // Nothing landed on disk. Three ways to get here, and the counters say
        // which: the file refused every write, the converter refused every
        // buffer because its input format is not the device's, or the
        // microphone sent nothing at all.
        if frames == 0 {
            let why: String
            if failed > 0 {
                why = "none of the \(failed) buffer(s) could be written to the file"
            } else if refused > 0 {
                why = "the converter refused all \(refused) buffer(s)"
                    + " — its input format is not the device's"
            } else {
                why = "the microphone delivered nothing"
            }
            Log.write("recording captured 0 frames — \(why)")
            try? FileManager.default.removeItem(at: url)
            report("Recorded nothing — the microphone was not ready. Press again.")
            rebuildEngine(because: "the last recording captured nothing")
            return nil
        }

        // Audio that was spoken and is not in the file. Two ways to lose it and
        // the same consequence: the converter refused a buffer because its
        // input format is no longer the device's, or the file refused a write.
        // Both leave the clip shorter than what was said.
        //
        // Always said out loud, however little was lost — the whole point of
        // #95 is that this used to be the silent path.
        let lost = Double(dropped) / config.audio.sampleRate
        if dropped > 0 {
            Log.write(String(
                format: "recording lost %.2fs — %d buffer(s) refused by the converter,"
                + " %d by the file", lost, refused, failed
            ))
        }
        // Past the tolerance the hole is big enough to be a word, and a
        // transcript with a word missing and nothing to say which one is the
        // failure this file is about, delivered as text instead of as nothing.
        // So it is not handed on.
        //
        // The file stays where it is. It is the evidence of what went wrong,
        // and deleting it is the opposite of useful — the same reason
        // `cancelDictation` leaves a cancelled clip alone.
        if lost > Self.droppedAudioTolerance {
            Log.write("\(url.lastPathComponent) is short and will not be transcribed")
            report("Part of that recording was lost. Say it again.")
            return nil
        }

        let rms = Float((energy / Double(frames)).squareRoot())
        if dropped > 0 {
            // Under the tolerance, so the clip is still worth transcribing —
            // but not worth passing off as whole. Clearing the warning here
            // would deliver a sentence missing its last syllable with nothing
            // on screen saying so, which is this file's own failure in a
            // smaller size. Transcribe it and say what went.
            report(String(format: "The last %.1fs of that recording was lost.", lost))
        } else if rms < Self.silenceFloor {
            // Frames arrived and they are all silence. A different fault again —
            // a muted device, the wrong microphone, a headset that connected
            // without its microphone — and the same cost to the person talking,
            // so it gets the same treatment.
            Log.write(String(format: "recording is silence — rms %.5f over %.2fs", rms, duration))
            report("Recorded silence — check which microphone is selected.")
        } else {
            report(nil)
        }

        return Recording(url: url, duration: duration, rms: rms)
    }

    private func teardown() {
        writeLock.lock()
        audioFile = nil
        writeLock.unlock()
        converter = nil
        targetFormat = nil
        currentURL = nil
        startedAt = nil
        smoothedLevel = 0
    }

    private func setRecording(_ value: Bool) {
        stateLock.lock()
        isRecording = value
        stateLock.unlock()
    }

    private func currentEngine() -> AVAudioEngine {
        stateLock.lock()
        defer { stateLock.unlock() }
        return engine
    }

    /// Says whether the last recording was usable. Nil clears a standing
    /// warning, so one good dictation puts the menu bar back.
    private func report(_ problem: String?) {
        DispatchQueue.main.async { [weak self] in self?.onCaptureProblem?(problem) }
    }

    // MARK: - Audio path

    /// Converts one tap buffer to 16 kHz mono and writes it.
    ///
    /// Not private: `--audio-recovery` pushes synthetic buffers through it to
    /// check the conversion without opening the microphone.
    func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        // The input block must hand the converter each buffer exactly once,
        // then report a dry input — otherwise `convert` spins forever.
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            // Every buffer takes this path when the converter was built from a
            // format the device has since left. `convert` reports `.error` and
            // still fills `outBuffer` with the right *number* of zeroed frames,
            // so a length check cannot see it — measured 3754 frames at rms
            // 0.00000 converting a 24 kHz buffer through a 48 kHz converter.
            // Counted rather than dropped in silence: this is #95.
            //
            // The frame count comes from the input buffer and the ratio, not
            // from `outBuffer`, whose length on this path describes a
            // conversion that did not happen.
            writeLock.lock()
            refusedBuffers += 1
            droppedFrames += Int64(Double(buffer.frameLength) * ratio)
            writeLock.unlock()
            return
        }
        guard outBuffer.frameLength > 0 else { return }

        let rms = Self.rootMeanSquare(of: outBuffer)

        writeLock.lock()
        // Counted only once it is on disk. Counting a buffer the file refused
        // would let `stop` report a healthy RMS over a clip that is empty or
        // short, and hand it to transcription — a silent failure of exactly
        // the kind this change exists to end, one layer along.
        // No file at all is a buffer arriving after `teardown`, not a failure:
        // the recording is already over and `stop` has read these totals.
        if let audioFile {
            do {
                try audioFile.write(from: outBuffer)
                capturedFrames += Int64(outBuffer.frameLength)
                capturedEnergy += Double(rms) * Double(rms) * Double(outBuffer.frameLength)
            } catch {
                failedWrites += 1
                droppedFrames += Int64(outBuffer.frameLength)
            }
        }
        writeLock.unlock()

        publishLevel(rms)
    }

    private static func rootMeanSquare(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        return sqrt(sum / Float(frames))
    }

    private func publishLevel(_ rms: Float) {
        // -60 dB floor, then a fast-attack / slow-release smooth so the meter
        // tracks speech instead of flickering on every buffer.
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 60) / 60))
        let coefficient: Float = normalized > smoothedLevel ? 0.5 : 0.12
        smoothedLevel += (normalized - smoothedLevel) * coefficient

        let level = smoothedLevel
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: - Device changes

    @objc private func configurationChanged(_ note: Notification) {
        guard isRecording else {
            DispatchQueue.main.async { [weak self] in self?.reacquireIfInputMoved() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.onUnexpectedStop?(nil)
        }
    }

    /// Delivers the notification the engine posts when its configuration
    /// changes, as if the engine had posted it.
    ///
    /// `--audio-recovery` drives the whole path with it — the observer, the
    /// comparison and the rebuild — rather than only the decision, so a change
    /// that forgets to move the observer onto the new engine still fails the
    /// check. Nothing in the app calls it.
    func simulateConfigurationChange() {
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: currentEngine()
        )
    }

    /// Rebuilds if what the system would hand us now differs from what the
    /// engine is bound to.
    ///
    /// The comparison is the whole binding, not just the device. Our own
    /// `prepare()` posts this notification and moves neither field, so the echo
    /// is still dropped — with no clock to be on the wrong side of, and a
    /// headset that announces itself five times still only moves the binding
    /// once. What is new is that a format moving on a device that stayed put
    /// now counts. That is what AirPods do while their link settles, and
    /// ignoring it is what left the engine converting from a format the
    /// hardware had left. See #95.
    private func reacquireIfInputMoved() {
        guard !isRecording else { return }

        stateLock.lock()
        let bound = self.bound
        stateLock.unlock()

        let current = currentInput()
        guard current != bound else { return }
        rebuildEngine(because: "input moved: \(Self.describe(bound)) → \(Self.describe(current))")
    }

    private static func describe(_ binding: InputBinding?) -> String {
        binding?.described ?? "no input device"
    }

    /// Why this format cannot be recorded through, or nil if it can.
    ///
    /// The second test is the one #95 needed. A format that disagrees with the
    /// device is not a broken format — it passes every guard, builds a
    /// converter, installs a tap — it is a format that used to be true.
    private static func formatProblem(
        _ format: AVAudioFormat, against input: InputBinding?
    ) -> String? {
        if format.sampleRate <= 0 || format.channelCount == 0 {
            return "the input format came back empty"
        }
        guard let input, input.sampleRate > 0 else { return nil }
        guard format.sampleRate != input.sampleRate else { return nil }
        return String(
            format: "the engine is at %.0f Hz and the device is at %.0f Hz",
            format.sampleRate, input.sampleRate
        )
    }

    /// Replaces the engine so the next recording acquires the current device.
    /// Re-preparing the existing one is not enough; it keeps the old device.
    ///
    /// The building happens on `engineQueue`, off the main thread — see that
    /// property for what it used to cost. Callers that need the new engine wait
    /// through `waitForRebuild`.
    private func rebuildEngine(because reason: String) {
        stateLock.lock()
        let busy = isRecording || rebuilding
        if !busy { rebuilding = true }
        stateLock.unlock()
        guard !busy else { return }

        Log.write("rebuilding the capture engine — \(reason)")
        rebuildGroup.enter()
        let started = Date()

        // Held strongly and left in a `defer`, so the group empties however this
        // block ends — including with the recorder already gone. A rebuild that
        // finishes without leaving it makes every later press wait 1.5s and
        // then refuse, forever, which is the wedge this whole change is about.
        let group = rebuildGroup
        engineQueue.async { [weak self] in
            defer {
                self?.finishRebuilding()
                group.leave()
            }
            let fresh = AVAudioEngine()
            // The expensive line: instantiating the input node opens the
            // device. Everything after it is cheap.
            _ = fresh.inputNode.outputFormat(forBus: 0)
            fresh.prepare()
            self?.adopt(fresh, took: Date().timeIntervalSince(started))
        }
    }

    private func finishRebuilding() {
        stateLock.lock()
        rebuilding = false
        stateLock.unlock()
    }

    /// Waits for an engine that is still being built, and gives up in time to
    /// be useful. See `rebuildWaitSeconds`.
    private func waitForRebuild() throws {
        guard rebuildGroup.wait(timeout: .now() + Self.rebuildWaitSeconds) == .timedOut else {
            return
        }
        Log.write("the input device is still connecting after \(Self.rebuildWaitSeconds)s")
        throw RecorderError.inputStillConnecting
    }

    /// Swaps a freshly built engine in. Runs on `engineQueue`.
    private func adopt(_ fresh: AVAudioEngine, took: TimeInterval) {
        let binding = currentInput()

        stateLock.lock()
        // A recording started while this was being built. It is running through
        // the old engine, so the old engine stays and `bound` is left alone —
        // the next `start` then sees a stale binding and builds another.
        guard !isRecording else {
            stateLock.unlock()
            Log.write("capture engine rebuilt while recording — kept the running one")
            return
        }
        let old = engine
        engine = fresh
        bound = binding
        rebuildCount += 1
        stateLock.unlock()

        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: old
        )
        observeConfigurationChanges(on: fresh)
        old.stop()

        Log.write(String(
            format: "capture engine rebuilt in %.1fs — mic=%@, %@",
            took, Self.inputDeviceName ?? "none", Self.describe(binding)
        ))
    }

    // MARK: - Device

    /// Which input device the system would hand us right now.
    ///
    /// Half of `InputBinding`, and kept on its own because the menu bar asks
    /// for the name and not the format.
    static var defaultInputDeviceID: AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    /// What the microphone is, in the words System Settings uses for it —
    /// "MacBook Pro Microphone", "Nathan's AirPods Pro". Nil when the machine
    /// has no input at all.
    ///
    /// The engine's input node follows the system's default input device; there
    /// is no per-app choice to make here, so the default is the answer. Asked
    /// of CoreAudio each time rather than remembered: it changes in System
    /// Settings and by plugging something in, neither of which this app sees.
    static var inputDeviceName: String? {
        guard let deviceID = defaultInputDeviceID else { return nil }
        return name(of: deviceID)
    }

    /// The default input, named and with its transport, from one lookup.
    ///
    /// One device ID, asked twice, rather than two properties that each ask
    /// which device is default. The default input can change between two such
    /// reads — a headset connects, and macOS makes it the input — and the pair
    /// then describes two devices: a wired microphone reported as Bluetooth,
    /// or the other way round. The callers of the single properties print a
    /// name and nothing else; this is the one that decides with both.
    static var inputDevice: (name: String, isBluetooth: Bool)? {
        guard let deviceID = defaultInputDeviceID, let name = name(of: deviceID) else { return nil }
        return (name, isBluetooth(deviceID))
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
        }
        guard status == noErr, let name = name as String? else { return nil }
        return name.isEmpty ? nil : name
    }

    /// Whether this device is on the other end of a Bluetooth link.
    ///
    /// Asked of CoreAudio, not of the name. A list of brands is a list that is
    /// wrong the day somebody buys a headset nobody thought of, and it was
    /// answering the wrong question anyway: what costs you the ends of your
    /// words is the transport. A Bluetooth microphone runs over a voice profile
    /// that narrows the band and gates quiet sound, and it does that whatever
    /// is printed on the case.
    private static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transport
        )
        guard status == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - Files

    private func makeOutputURL(config: Config) throws -> URL {
        let dir = config.resolvedOutputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let name = "parrotflow-\(formatter.string(from: Date())).wav"
        return dir.appendingPathComponent(name)
    }
}
