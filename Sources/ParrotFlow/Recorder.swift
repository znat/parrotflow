import AVFoundation
import CoreAudio
import Foundation

/// Captures one input device through `AVCaptureSession` and writes 16 kHz mono
/// PCM WAV files — the format Parakeet expects, so the transcription step can
/// read them as-is.
///
/// `AVCaptureSession` rather than `AVAudioEngine` because an engine does not
/// record through the device you point it at. macOS builds it a private
/// aggregate, `CADefaultDeviceAggregate-<pid>-0`, out of the default *output*
/// device and the default input, and the graph runs at the output's rate.
/// Measured here on 2026-09-09: a Bluetooth speaker at 44100 Hz and a USB
/// microphone at 48000 Hz, one engine per process, and a node whose two halves
/// then disagree. See docs/architecture.md.
final class Recorder {

    struct Recording {
        let url: URL
        let duration: TimeInterval
        /// Root-mean-square of the whole clip, 0...1. Says whether anything was
        /// heard, which the duration cannot: a lost take and a good one are the
        /// same length. See `silenceFloor`.
        let rms: Float
        /// When the first buffer reached the file. The recording starts here,
        /// not at `startedAt`: `startRunning()` returns before the device
        /// delivers anything, and whatever was said in between is not in the
        /// clip. Nil when nothing was captured.
        let firstSampleAt: Date?
    }

    /// What the recorder is bound to: which input device, and the format that
    /// device is running at.
    ///
    /// Both halves matter. A device can keep its identity and change its format
    /// — AirPods do it a second or two after they become the input, while the
    /// Bluetooth link settles — and an identity test alone reads that as
    /// "nothing moved". See #95.
    struct InputBinding: Equatable {
        let device: AudioDeviceID
        let sampleRate: Double
        let channels: UInt32

        var described: String {
            "device \(device) at \(Int(sampleRate)) Hz, \(channels) ch"
        }

        /// What CoreAudio would hand us right now. Nil when the machine has no
        /// input device at all.
        static func system() -> InputBinding? {
            guard let device = Recorder.defaultInputDeviceID else { return nil }
            return of(device)
        }

        /// The same reading, of a named device rather than of the default one.
        /// What a `microphones:` entry resolves to.
        static func of(_ device: AudioDeviceID) -> InputBinding {
            guard let format = inputStreamFormat(of: device) else {
                // A device with no input stream to ask. Zeroes still compare,
                // which is all the change detection needs.
                return InputBinding(device: device, sampleRate: 0, channels: 0)
            }
            return InputBinding(
                device: device,
                sampleRate: format.mSampleRate,
                channels: format.mChannelsPerFrame
            )
        }

        static func inputStreamFormat(
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

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device is available."
            case .unsupportedFormat:
                return "Could not build a 16 kHz mono format."
            }
        }
    }

    /// Below this, a clip is silence rather than a quiet room.
    ///
    /// -60 dBFS. The lost takes in #95 measured 0.0001 here; the working takes
    /// beside them measured 0.021, and a live microphone in a quiet room sits
    /// around 0.003. So the floor cannot fire on speech and cannot miss a dead
    /// clip.
    static let silenceFloor: Float = 0.001

    /// How much lost audio a clip can carry and still be worth transcribing.
    ///
    /// Not zero: a device change ends a recording through `onUnexpectedStop`,
    /// and a buffer in the new format can arrive before that hop reaches the
    /// main queue. Not unbounded: past a certain hole the transcript is a
    /// sentence with words missing and nothing to say which. 0.3s covers one
    /// buffer at every rate a microphone runs at.
    static let droppedAudioTolerance: TimeInterval = 0.3

    /// How long a device that refused to open is skipped for.
    ///
    /// A device can refuse for a reason that passes — another app holding it, a
    /// link still settling — and no device-list change announces it coming
    /// back. A minute is long enough that a broken microphone is not retried on
    /// every press, and short enough that one which recovered is picked up
    /// again without anybody going looking for a setting.
    private static let refusalSeconds: TimeInterval = 60

    /// Past this, starting the session is worth a line in the log. Measured
    /// here: 107-109 ms warm, 143 ms cold.
    private static let slowStartSeconds: Double = 0.3

    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// How many times this recorder has moved its session onto a different
    /// binding. Read by `--audio-recovery` to see whether a device change was
    /// acted on, from a different thread than the one that counts them.
    var rebuilds: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rebindCount
    }
    private var rebindCount = 0

    /// 0...1, already smoothed — drive a meter with it. Called on the main queue.
    var onLevel: ((Float) -> Void)?
    /// The microphone has started sending. Called once per recording, on the
    /// main queue, and not at all for a recording that captured nothing.
    ///
    /// This is the moment a cue can honestly claim the app is listening.
    /// `start` returning cannot: it means the session is running, which is a
    /// state the device has not reached yet.
    ///
    /// Never called for a recording that has already ended. The block is
    /// queued from the capture queue and carries the take it was queued for, so
    /// one that arrives late is dropped rather than delivered against whatever
    /// is recording by then.
    var onFirstBuffer: (() -> Void)?
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
    ///
    /// Only consulted when no `microphones:` entry matched. A configured
    /// microphone is not what the system would hand us — it is what we go and
    /// take — and `desiredInput` reads it from the device itself.
    var currentInput: () -> InputBinding? = InputBinding.system

    /// The microphones this recorder prefers, best first — `audio.microphones`
    /// from the config, by name or by UID.
    ///
    /// Empty by default, which is the system's own choice and the behaviour
    /// this app had before: whatever System Settings calls the input device.
    /// Set from `applyConfig`, so it moves on every save of `config.yaml`.
    var preferredMicrophones: [String] = []

    /// The session and the output it delivers through. Rebuilt whenever the
    /// binding moves. Guarded by `stateLock`.
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var device: AVCaptureDevice?
    /// The binding the session was last built against — what it will actually
    /// record through, which is not always what the system would hand us today.
    /// Guarded by `stateLock`.
    private var bound: InputBinding?
    /// True once something has bound a device. A device-list change before that
    /// is ignored: building the input is what makes AVFoundation put up the
    /// native microphone dialog, and at that moment the permissions window has
    /// not yet said why. Set by `bind`, not by `warmUp` alone — a launch with
    /// the permission still unanswered skips the warm-up, and the first press
    /// is what binds. Guarded by `stateLock`.
    private var warmed = false
    /// Kept so `deinit` can take it off again — `AudioObjectRemovePropertyListenerBlock`
    /// matches on the block, not on a token.
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    /// The disconnect and runtime-error observers for the session in place.
    /// Guarded by `stateLock`.
    private var captureObservers: [NSObjectProtocol] = []
    /// Devices that were there and would not open, and when they refused.
    /// Skipped by the resolution, so the priority list falls past one the same
    /// way it falls past one that is unplugged. Guarded by `stateLock`.
    private var unopenable: [AudioDeviceID: Date] = [:]
    private let stateLock = NSLock()

    /// The rate the output is asked to deliver. AVCapture does the conversion,
    /// so this is the rate the buffers arrive at.
    private var outputSampleRate: Double = 16000

    /// Where sample buffers are delivered. Serial: `process` writes the file.
    private let captureQueue = DispatchQueue(label: "com.parrotflow.recorder.capture")
    /// Stops and lets go of a session a rebind replaced. `stopRunning` blocks
    /// for as long as the device takes to close.
    private let releaseQueue = DispatchQueue(label: "com.parrotflow.recorder.release")
    private let sink = CaptureSink()

    private let writeLock = NSLock()
    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private var smoothedLevel: Float = 0
    /// What reached disk, what did not, and why — all guarded by `writeLock`, so
    /// `stop` reads totals that match the file it is about to hand back.
    ///
    /// `capturedFrames` counts what reached disk. `droppedFrames` is what did
    /// not, in frames at the output rate, so `stop` can say how many seconds
    /// went missing rather than how many buffers.
    private var capturedFrames: Int64 = 0
    private var capturedEnergy: Double = 0
    /// When the first buffer was written, under `writeLock` with the counter
    /// that decides it is the first.
    private var firstBufferAt: Date?
    /// How many recordings this recorder has opened. A block queued for one of
    /// them carries the number, so it cannot be delivered against a later one.
    private var takes: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var refusedBuffers: Int = 0
    private var failedWrites: Int = 0

    init() {
        sink.recorder = self
        watchDeviceList()
    }

    deinit {
        if let listener = deviceListListener {
            var address = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
        }
        for token in captureObservers { NotificationCenter.default.removeObserver(token) }
        session?.stopRunning()
    }

    /// Builds the session — resolves the device, adds the input and the output,
    /// commits — so the first `start()` only has to run it.
    ///
    /// This does not open the input stream. Nothing is running, so the orange
    /// microphone indicator stays off until `start()` does.
    func warmUp() {
        bind(to: desiredInput(), counting: false)
    }

    // MARK: - Start

    @discardableResult
    func start(config: Config) throws -> URL {
        guard !isRecording else { return currentURL! }

        // The session keeps the device *and the format* it was built against.
        // If either has moved since, rebuild before the file is opened.
        rebindIfInputMoved()

        apply(sampleRate: config.audio.sampleRate)

        stateLock.lock()
        let session = self.session
        stateLock.unlock()
        guard let session else { throw RecorderError.noInputDevice }

        let url = try openCapture(config: config)

        let began = Date()
        session.startRunning()
        let took = Date().timeIntervalSince(began)
        if took > Self.slowStartSeconds {
            Log.write(String(format: "the capture session took %.0f ms to start", took * 1000))
        }

        guard session.isRunning else {
            teardown()
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.noInputDevice
        }

        beginRecording()
        return url
    }

    /// Builds what the capture output writes into: the file on disk.
    ///
    /// Split out of `start` so `--audio-recovery` can push buffers through the
    /// exact path the delegate uses without opening the microphone. Nothing in
    /// the app calls it directly.
    ///
    /// - Parameter markRecording: whether to enter the recording state here.
    ///   `start` leaves it false and calls `beginRecording` only once the
    ///   session is running.
    @discardableResult
    func openCapture(config: Config, markRecording: Bool = false) throws -> URL {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.audio.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.unsupportedFormat
        }

        let url = try makeOutputURL(config: config)
        // Float32 in memory, 16-bit PCM on disk: small files, no quality loss
        // that matters at 16 kHz speech.
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: target.sampleRate,
                AVNumberOfChannelsKey: target.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        currentURL = url

        writeLock.lock()
        audioFile = file
        takes += 1
        capturedFrames = 0
        capturedEnergy = 0
        firstBufferAt = nil
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

        stateLock.lock()
        let session = self.session
        stateLock.unlock()
        session?.stopRunning()

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let opened = startedAt
        let url = currentURL

        writeLock.lock()
        let frames = capturedFrames
        let energy = capturedEnergy
        let refused = refusedBuffers
        let failed = failedWrites
        let dropped = droppedFrames
        // Read here rather than at the caller: `teardown` is a line away and
        // the counters are only readable until it runs.
        let firstSample = firstBufferAt
        writeLock.unlock()

        teardown()

        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }

        // The device may have moved while this recording was running — that is
        // one of the things that ends one early. Re-acquire now rather than at
        // the next press, so the press finds a session that is already right.
        rebindIfInputMoved()

        guard let url else { return nil }
        guard duration >= config.audio.minDurationSeconds else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        // Nothing landed on disk. Three ways to get here, and the counters say
        // which: the file refused every write, the buffers arrived in a format
        // the file cannot take, or the microphone sent nothing at all.
        if frames == 0 {
            let why: String
            if failed > 0 {
                why = "none of the \(failed) buffer(s) could be written to the file"
            } else if refused > 0 {
                why = "all \(refused) buffer(s) arrived in a format the file could not take"
            } else {
                why = "the microphone delivered nothing"
            }
            Log.write("recording captured 0 frames — \(why)")
            try? FileManager.default.removeItem(at: url)
            report("Recorded nothing — the microphone was not ready. Press again.")
            rebuildSession(because: "the last recording captured nothing")
            return nil
        }

        // What the clip cost before it existed. `startRunning()` returns as
        // soon as the session is running, which is not when the device starts
        // sending — so this is speech that was said and not recorded, and it is
        // a number rather than an anecdote only because it is logged.
        if let firstSample, let opened {
            Log.write(String(
                format: "first sample %.0f ms after the session started",
                firstSample.timeIntervalSince(opened) * 1000
            ))
        }

        // Audio that was spoken and is not in the file: a buffer in a format
        // the file cannot take, or a write the file refused. Both leave the
        // clip shorter than what was said.
        //
        // Always said out loud, however little was lost — the whole point of
        // #95 is that this used to be the silent path.
        let lost = Double(dropped) / config.audio.sampleRate
        if dropped > 0 {
            Log.write(String(
                format: "recording lost %.2fs — %d buffer(s) refused by the format check,"
                + " %d by the file", lost, refused, failed
            ))
        }
        // Past the tolerance the hole is big enough to be a word, and a
        // transcript with a word missing and nothing to say which one is the
        // failure this file is about, delivered as text instead of as nothing.
        //
        // The file stays where it is, unless `logging.audio` says recordings do
        // not accumulate at all — that setting is about not keeping your voice
        // on disk, and a partial clip is still your voice.
        if lost > Self.droppedAudioTolerance {
            Log.write("\(url.lastPathComponent) is short and will not be transcribed")
            if !config.logging.audio {
                try? FileManager.default.removeItem(at: url)
            }
            report("Part of that recording was lost. Say it again.")
            return nil
        }

        let rms = Float((energy / Double(frames)).squareRoot())
        if dropped > 0 {
            // Under the tolerance, so the clip is still worth transcribing —
            // but not worth passing off as whole.
            report(String(format: "The last %.1fs of that recording was lost.", lost))
        } else if rms < Self.silenceFloor {
            // Frames arrived and they are all silence. A different fault again —
            // a muted device, the wrong microphone, a headset that connected
            // without its microphone — and the same cost to the person talking.
            Log.write(String(format: "recording is silence — rms %.5f over %.2fs", rms, duration))
            report("Recorded silence — check which microphone is selected.")
        } else {
            report(nil)
        }

        return Recording(url: url, duration: duration, rms: rms, firstSampleAt: firstSample)
    }

    private func teardown() {
        writeLock.lock()
        audioFile = nil
        writeLock.unlock()
        currentURL = nil
        startedAt = nil
        smoothedLevel = 0
    }

    private func setRecording(_ value: Bool) {
        stateLock.lock()
        isRecording = value
        stateLock.unlock()
    }

    /// Says whether the last recording was usable. Nil clears a standing
    /// warning, so one good dictation puts the menu bar back.
    private func report(_ problem: String?) {
        DispatchQueue.main.async { [weak self] in self?.onCaptureProblem?(problem) }
    }

    // MARK: - Audio path

    /// The format a buffer has to arrive in to be written: the open file's own.
    /// Nil when no recording is open.
    fileprivate var writeFormat: AVAudioFormat? {
        writeLock.lock()
        defer { writeLock.unlock() }
        return audioFile?.processingFormat
    }

    /// Writes one buffer from the capture output.
    ///
    /// Not private: `--audio-recovery` pushes synthetic buffers through it to
    /// check the path without opening the microphone.
    func process(buffer: AVAudioPCMBuffer) {
        writeLock.lock()
        let file = audioFile
        writeLock.unlock()
        guard let file else { return }
        let target = file.processingFormat

        guard Self.matches(buffer.format, target) else {
            // The safety net from #95, without the converter that used to be
            // it. AVCapture is asked for one format and delivers it, so nothing
            // should take this path — and a buffer that does is audio that was
            // spoken and is not on disk, which `stop` has to be able to say.
            let ratio = buffer.format.sampleRate > 0
                ? target.sampleRate / buffer.format.sampleRate : 1
            writeLock.lock()
            refusedBuffers += 1
            droppedFrames += Int64(Double(buffer.frameLength) * ratio)
            writeLock.unlock()
            return
        }
        guard buffer.frameLength > 0 else { return }

        let rms = Self.rootMeanSquare(of: buffer)

        var firstOfTake: Int64?
        writeLock.lock()
        // Counted only once it is on disk. Counting a buffer the file refused
        // would let `stop` report a healthy RMS over a clip that is empty or
        // short, and hand it to transcription.
        // No file at all is a buffer arriving after `teardown`, not a failure.
        if let audioFile {
            do {
                try audioFile.write(from: buffer)
                // The clip's real beginning. Taken from the same branch that
                // counts the frame, so it cannot mark a buffer the file refused.
                if capturedFrames == 0 {
                    firstBufferAt = Date()
                    firstOfTake = takes
                }
                capturedFrames += Int64(buffer.frameLength)
                capturedEnergy += Double(rms) * Double(rms) * Double(buffer.frameLength)
            } catch {
                failedWrites += 1
                droppedFrames += Int64(buffer.frameLength)
            }
        }
        writeLock.unlock()

        if let firstOfTake {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.take == firstOfTake else { return }
                self.onFirstBuffer?()
            }
        }
        publishLevel(rms, seconds: Double(buffer.frameLength) / target.sampleRate)
    }

    /// Whether a buffer can be handed to the file as it stands. Field by field,
    /// not `==`: two formats that differ only in the interleaved flag are the
    /// same memory for one channel, and `AVAudioFormat` still calls them unequal.
    private static func matches(_ format: AVAudioFormat, _ target: AVAudioFormat) -> Bool {
        format.sampleRate == target.sampleRate
            && format.channelCount == target.channelCount
            && format.commonFormat == target.commonFormat
            && format.isInterleaved == target.isInterleaved
    }

    /// Which recording is open now. Compared against the take a queued block
    /// was made for; `openCapture` moves it.
    private var take: Int64 {
        writeLock.lock()
        defer { writeLock.unlock() }
        return takes
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

    /// The meter's fast attack and slow release, as time constants.
    ///
    /// They were 0.5 and 0.12 applied once per buffer, tuned when a buffer was
    /// 85 ms (4096 frames at 48 kHz). AVCapture delivers about 10 ms, which
    /// would make the same numbers eight times twitchier, so the coefficient is
    /// derived from each buffer's own length instead: τ = −0.0853 / ln(1 − α).
    private static let attackSeconds: Double = 0.123
    private static let releaseSeconds: Double = 0.667

    private func publishLevel(_ rms: Float, seconds: Double) {
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 60) / 60))
        let tau = normalized > smoothedLevel ? Self.attackSeconds : Self.releaseSeconds
        let coefficient = Float(1 - exp(-max(seconds, 0) / tau))
        smoothedLevel += (normalized - smoothedLevel) * coefficient

        let level = smoothedLevel
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: - Device changes

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Watches for microphones arriving and leaving.
    ///
    /// Ignored while recording. A device appearing is not a reason to take the
    /// microphone away from a sentence somebody is halfway through; the next
    /// press picks it up.
    private func watchDeviceList() {
        var address = Self.deviceListAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceListChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        )
        guard status == noErr else {
            Log.write("could not watch the microphone list: CoreAudio returned \(status)")
            return
        }
        deviceListListener = listener
    }

    /// What the CoreAudio listener does. Also what `simulateDeviceListChange`
    /// calls, so a check drives the whole path and not only the comparison.
    private func deviceListChanged() {
        // A device that refused to open gets its chance back early when the
        // hardware moves. The IDs move with it, so keeping the old set would
        // skip a device that never refused anything.
        stateLock.lock()
        unopenable.removeAll()
        stateLock.unlock()
        reevaluateInput()
    }

    /// Delivers a microphone arriving or leaving, as CoreAudio delivers it.
    ///
    /// `--audio-recovery` drives the whole path with it — the listener body,
    /// the comparison and the rebind — rather than only the decision. Nothing
    /// in the app calls it.
    func simulateDeviceListChange() {
        deviceListChanged()
    }

    /// Re-reads the priority list and rebinds if it now names a different
    /// microphone.
    ///
    /// Called after every config load and whenever a device is attached or
    /// removed. Both of those happen before anything has opened the microphone,
    /// which is why nothing here builds the first session: building the input is
    /// what makes AVFoundation put up the native microphone dialog, and at that
    /// moment the permissions window has not yet said why. So it returns until
    /// something else has bound a device — `warmUp`, or the first press.
    func reevaluateInput() {
        stateLock.lock()
        let started = warmed
        stateLock.unlock()
        guard started else { return }
        DispatchQueue.main.async { [weak self] in self?.rebindIfInputMoved() }
    }

    /// What the next session should be bound to, and which device to open for
    /// it.
    ///
    /// `pin` is nil when nothing in `microphones:` matched — the unpinned path,
    /// where the recorder follows the system's default input.
    ///
    /// One resolution, two answers, on purpose. Asking twice — once for the
    /// binding to remember and once for the device to open — can straddle a
    /// microphone connecting, and then `bound` names a device the session was
    /// never opened against.
    func desiredInput() -> (binding: InputBinding?, pin: AudioDeviceID?) {
        stateLock.lock()
        // A refusal expires here rather than on a timer. Nothing fires on its
        // own then: the retry happens on the next press or reload after the
        // minute is up, which is the moment it is worth anything.
        let cutoff = Date().addingTimeInterval(-Self.refusalSeconds)
        unopenable = unopenable.filter { $0.value > cutoff }
        let refused = Set(unopenable.keys)
        stateLock.unlock()
        guard let device = Self.preferredDevice(
            from: preferredMicrophones, excluding: refused
        ) else {
            return (currentInput(), nil)
        }
        return (InputBinding.of(device.id), device.id)
    }

    /// Rebuilds the session if what we want now differs from what it is on.
    ///
    /// The comparison is the whole binding, not just the device: a format
    /// moving on a device that stayed put counts. That is what AirPods do while
    /// their link settles. See #95.
    private func rebindIfInputMoved() {
        guard !isRecording else { return }

        let desired = desiredInput()
        stateLock.lock()
        let current = bound
        stateLock.unlock()

        guard desired.binding != current else { return }
        Log.write(
            "rebinding the capture session — input moved:"
            + " \(Self.describe(current)) → \(Self.describe(desired.binding))"
        )
        bind(to: desired, counting: true)
    }

    /// Rebuilds the session against whatever we want right now, whether or not
    /// the binding moved. What `stop` reaches for when a take captured nothing.
    private func rebuildSession(because reason: String) {
        guard !isRecording else { return }
        Log.write("rebuilding the capture session — \(reason)")
        bind(to: desiredInput(), counting: true)
    }

    /// Points the session at one binding: resolve the device, build a session
    /// around it, swap it in, and let the old one go.
    ///
    /// A binding whose device resolves to no `AVCaptureDevice` is still adopted.
    /// The recorder then has a binding and no session, `start` says there is no
    /// input device, and the next change is compared against what we wanted
    /// rather than against what we last managed to open.
    private func bind(to desired: (binding: InputBinding?, pin: AudioDeviceID?), counting: Bool) {
        let deviceID = desired.pin ?? desired.binding?.device
        let device = deviceID.flatMap { Self.captureDevice(for: $0) }
        let built = device.flatMap { make(session: $0, for: deviceID) }

        stateLock.lock()
        let old = session
        session = built?.session
        output = built?.output
        self.device = device
        bound = desired.binding
        warmed = true
        if counting { rebindCount += 1 }
        stateLock.unlock()

        observe(session: built?.session, device: device)
        release(old)

        Log.write(
            "capture session on \(device?.localizedName ?? "no device")"
            + " — \(Self.describe(desired.binding))"
        )
    }

    /// One session, one input, one output that hands us 16 kHz mono float.
    ///
    /// Nil when the device will not open. The caller then keeps the binding and
    /// no session, and the device is skipped for a minute.
    private func make(
        session device: AVCaptureDevice, for deviceID: AudioDeviceID?
    ) -> (session: AVCaptureSession, output: AVCaptureAudioDataOutput)? {
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            Log.write("could not open microphone \(device.localizedName): \(error.localizedDescription)")
            if let deviceID {
                stateLock.lock()
                unopenable[deviceID] = Date()
                stateLock.unlock()
            }
            return nil
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = Self.audioSettings(rate: outputSampleRate)
        output.setSampleBufferDelegate(sink, queue: captureQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            Log.write("the capture session would not take \(device.localizedName)")
            return nil
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        return (session, output)
    }

    /// What the output is asked to deliver. AVCapture converts to it, which is
    /// the whole reason there is no converter here any more.
    private static func audioSettings(rate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Moves the output onto the config's sample rate, if it is not there. A
    /// reconfiguration, not a rebuild: it does not touch the device.
    private func apply(sampleRate: Double) {
        stateLock.lock()
        let changed = outputSampleRate != sampleRate
        if changed { outputSampleRate = sampleRate }
        let session = self.session
        let output = self.output
        stateLock.unlock()
        guard changed, let session, let output else { return }
        session.beginConfiguration()
        output.audioSettings = Self.audioSettings(rate: sampleRate)
        session.commitConfiguration()
    }

    /// Both ways a running capture can end without us asking.
    ///
    /// A format change on the same device is not one of them: AVCapture handles
    /// that itself and keeps delivering at the rate we asked for.
    private func observe(session: AVCaptureSession?, device: AVCaptureDevice?) {
        let center = NotificationCenter.default
        stateLock.lock()
        let old = captureObservers
        var fresh: [NSObjectProtocol] = []
        if let device {
            fresh.append(center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main
            ) { [weak self] _ in self?.captureEnded() })
        }
        if let session {
            fresh.append(center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
            ) { [weak self] _ in self?.captureEnded() })
        }
        captureObservers = fresh
        stateLock.unlock()
        for token in old { center.removeObserver(token) }
    }

    private func captureEnded() {
        guard isRecording else { return }
        onUnexpectedStop?(nil)
    }

    /// Stops and lets go of the session a rebind replaced, off the main thread.
    /// `stopRunning` blocks for as long as the device takes to close, and on
    /// Bluetooth that has been seconds.
    private func release(_ old: AVCaptureSession?) {
        guard let old else { return }
        releaseQueue.async {
            let began = Date()
            if old.isRunning { old.stopRunning() }
            let took = Date().timeIntervalSince(began)
            if took > 1 {
                Log.write(String(format: "letting go of a capture session took %.1fs", took))
            }
        }
    }

    private static func describe(_ binding: InputBinding?) -> String {
        binding?.described ?? "no input device"
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
    /// The system's own answer, which is this app's only when `microphones:`
    /// is empty or names nothing attached. What the next press will actually
    /// listen through is `boundDevice`.
    static var inputDeviceName: String? {
        guard let deviceID = defaultInputDeviceID else { return nil }
        return name(of: deviceID)
    }

    /// A microphone: what to call it, and what to decide about it with.
    struct InputDevice {
        /// What CoreAudio calls it today. Not written down anywhere: it is
        /// handed back out to the next device after a reconnection, and it
        /// moves when a device's sample rate changes — measured here, the
        /// built-in microphone went from 109 to 108 on a rate change.
        let id: AudioDeviceID
        /// CoreAudio's UID for the device. What tells two microphones apart,
        /// including two that answer to the same name. Stable across
        /// unplugging and reconnecting, which `AudioDeviceID` is not.
        let uid: String
        /// What System Settings calls it, and what the notice says out loud.
        let name: String
        let isBluetooth: Bool
    }

    /// Every microphone attached right now, in CoreAudio's own order.
    ///
    /// Filtered to devices with an input stream, so speakers and the loopback
    /// halves of virtual devices are not offered as things to record through.
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard InputBinding.inputStreamFormat(of: id) != nil else { return nil }
            return inputDevice(id)
        }
    }

    /// The device one `microphones:` entry names, or nil if nothing attached
    /// answers to it.
    ///
    /// An entry is a UID or a name, matched without case. Exact first, over
    /// every device, and only then as a fragment: "AirPods" should reach
    /// "Nathan's AirPods Pro", and a device actually called "Display Audio"
    /// should not lose to one called "Display Audio (2)".
    static func device(named entry: String, among devices: [InputDevice]) -> InputDevice? {
        let wanted = entry.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = devices.first(where: {
            $0.uid.lowercased() == wanted || $0.name.lowercased() == wanted
        }) {
            return exact
        }
        return devices.first { $0.name.lowercased().contains(wanted) }
    }

    /// The highest-priority microphone in the list that is attached right now,
    /// or nil when none of them is.
    ///
    /// Nil is not a failure. It is the answer that leaves the recorder
    /// following the system's default input, which is what an empty list means.
    static func preferredDevice(
        from entries: [String], excluding refused: Set<AudioDeviceID> = []
    ) -> InputDevice? {
        guard !entries.isEmpty else { return nil }
        let attached = inputDevices().filter { !refused.contains($0.id) }
        for entry in entries {
            if let device = device(named: entry, among: attached) { return device }
        }
        return nil
    }

    /// The `AVCaptureDevice` for a CoreAudio device.
    ///
    /// By UID first: `AVCaptureDevice.uniqueID` is the CoreAudio UID string,
    /// measured here for the built-in microphone and for a USB one. Not
    /// verified for Bluetooth, which is what the name fallback is for.
    private static func captureDevice(for deviceID: AudioDeviceID) -> AVCaptureDevice? {
        if let uid = uid(of: deviceID) {
            if let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) {
                return device
            }
            Log.write("no capture device answers to \(uid); matching on the name instead")
        }
        guard let name = name(of: deviceID) else { return nil }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.first { $0.localizedName == name }
    }

    /// One device ID, read out into the three things anything here asks of a
    /// microphone. Nil when the ID names nothing — it can go stale between
    /// being listed and being read.
    private static func inputDevice(_ deviceID: AudioDeviceID) -> InputDevice? {
        guard let name = name(of: deviceID) else { return nil }
        // The device ID stands in where a device will not give a UID — never
        // the name, which is what a UID is here to be better than.
        return InputDevice(
            id: deviceID,
            uid: uid(of: deviceID) ?? "device-id:\(deviceID)",
            name: name,
            isBluetooth: isBluetooth(deviceID)
        )
    }

    /// The device this recorder is bound to.
    ///
    /// Asked of the recorder's own binding, not of the system default. `bound`
    /// is the device the session was built against, which is the one the words
    /// are being recorded through; the default can move the moment after
    /// `start` returns. Nil before the first session is built.
    var boundDevice: InputDevice? {
        stateLock.lock()
        let deviceID = bound?.device
        stateLock.unlock()
        guard let deviceID else { return nil }
        return Self.inputDevice(deviceID)
    }

    /// The capture device the session is actually on, in AVFoundation's own
    /// words. Printed by `--audio-recovery`; nothing in the app reads it.
    var captureDeviceID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return device?.uniqueID
    }

    /// Whether anything on this Mac has this device open.
    ///
    /// Read by `--audio-recovery` to show that warming up does not. System-wide:
    /// another app holding the microphone reads the same as this one holding it.
    static func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &running
        )
        return status == noErr && running != 0
    }

    /// The device's own identifier, the one that outlives a reconnection.
    private static func uid(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid = uid as String?, !uid.isEmpty else { return nil }
        return uid
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
    /// Asked of CoreAudio, not of the name. A list of brands is wrong the day
    /// somebody buys a headset nobody thought of, and it answers the wrong
    /// question anyway: what costs you the ends of your words is the transport.
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
        // The timestamp alone is only second-precision, and push-to-talk does
        // not wait for the previous dictation's transcription before starting
        // the next recording — two presses inside the same second would name
        // the same file, and one clip's cleanup would delete the other.
        let suffix = UUID().uuidString.prefix(8)
        let name = "parrotflow-\(formatter.string(from: Date()))-\(suffix).wav"
        return dir.appendingPathComponent(name)
    }

    /// Removes a clip once nothing needs the file on disk any more, unless
    /// `logging.audio` says to keep it.
    ///
    /// Not folded into `stop()`: the caller still needs the file to exist right
    /// after `stop()` returns, to hand it to the transcriber. `--record`,
    /// `--audio-recovery` and the rest of the terminal commands manage their own
    /// clips directly and never call this.
    static func discardIfNotKept(_ recording: Recording, config: Config) {
        guard !config.logging.audio else { return }
        try? FileManager.default.removeItem(at: recording.url)
    }
}

/// Takes the sample buffers off the capture output and hands them to the
/// recorder as `AVAudioPCMBuffer`s.
///
/// Its own class because `AVCaptureAudioDataOutputSampleBufferDelegate` is an
/// Objective-C protocol and `Recorder` is not an `NSObject`.
private final class CaptureSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var recorder: Recorder?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let recorder, let target = recorder.writeFormat else { return }
        guard let buffer = Self.buffer(from: sampleBuffer, wantedAs: target) else { return }
        recorder.process(buffer: buffer)
    }

    /// One `CMSampleBuffer` as an `AVAudioPCMBuffer`.
    ///
    /// Wrapped at `target` when the stream describes the same audio, so the
    /// file can take it as it stands — `audioSettings` asks for interleaved and
    /// the file's format is not, which for one channel is the same bytes and a
    /// different flag. Anything else is wrapped at its own format, carries no
    /// samples, and is refused by `process` as lost audio.
    private static func buffer(
        from sample: CMSampleBuffer, wantedAs target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0 else { return nil }

        guard matches(asbd, target) else {
            guard let format = AVAudioFormat(streamDescription: &asbd),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else { return nil }
            buffer.frameLength = frames
            return buffer
        }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let source = list.mBuffers.mData,
              let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames),
              let destination = buffer.floatChannelData?[0]
        else { return nil }

        return withExtendedLifetime(blockBuffer) {
            let bytes = min(Int(list.mBuffers.mDataByteSize), Int(frames) * MemoryLayout<Float>.size)
            destination.withMemoryRebound(to: UInt8.self, capacity: bytes) {
                $0.update(from: source.assumingMemoryBound(to: UInt8.self), count: bytes)
            }
            buffer.frameLength = AVAudioFrameCount(bytes / MemoryLayout<Float>.size)
            return buffer
        }
    }

    /// Whether the stream is the audio the file wants, whatever the interleaved
    /// flag says.
    private static func matches(_ asbd: AudioStreamBasicDescription, _ target: AVAudioFormat) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mBitsPerChannel == 32
            && asbd.mSampleRate == target.sampleRate
            && asbd.mChannelsPerFrame == target.channelCount
    }
}
