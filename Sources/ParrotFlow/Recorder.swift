import AVFoundation
import Foundation

/// Captures the default input device and writes 16 kHz mono PCM WAV files —
/// the format Parakeet expects, so the transcription step can read them as-is.
final class Recorder {

    struct Recording {
        let url: URL
        let duration: TimeInterval
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case unsupportedFormat
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device is available."
            case .unsupportedFormat:
                return "Could not build a 16 kHz mono format."
            case .converterUnavailable:
                return "Could not convert the microphone's format to 16 kHz mono."
            }
        }
    }

    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// 0...1, already smoothed — drive a meter with it. Called on the main queue.
    var onLevel: ((Float) -> Void)?
    /// Fired when recording stops on its own (e.g. the audio device changed).
    var onUnexpectedStop: ((Error?) -> Void)?

    /// Recreated when the audio device changes — an engine holds on to the
    /// device it was prepared against.
    private var engine = AVAudioEngine()
    private let writeLock = NSLock()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var currentURL: URL?
    private var smoothedLevel: Float = 0

    init() {
        observeConfigurationChanges()
    }

    private func observeConfigurationChanges() {
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
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    // MARK: - Start

    @discardableResult
    func start(config: Config) throws -> URL {
        guard !isRecording else { return currentURL! }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

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

        isRecording = true
        startedAt = Date()
        return url
    }

    // MARK: - Stop

    /// Returns nil if the clip was shorter than `min_duration_seconds` (the file
    /// is deleted in that case) or if nothing was recording.
    @discardableResult
    func stop(config: Config) -> Recording? {
        guard isRecording else { return nil }
        isRecording = false

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let url = currentURL
        teardown()

        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }

        guard let url else { return nil }
        guard duration >= config.audio.minDurationSeconds else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        // No frames despite a real duration means the engine was bound to a
        // device that is no longer there. Silent failure looks identical to a
        // silent room, so say it and re-acquire.
        if let file = try? AVAudioFile(forReading: url), file.length == 0 {
            Log.write("recording captured 0 frames — rebuilding the capture engine")
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { [weak self] in self?.rebuildEngine() }
            return nil
        }
        return Recording(url: url, duration: duration)
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

    // MARK: - Audio path

    private func process(buffer: AVAudioPCMBuffer) {
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

        guard status != .error, outBuffer.frameLength > 0 else { return }

        writeLock.lock()
        try? audioFile?.write(from: outBuffer)
        writeLock.unlock()

        publishLevel(from: outBuffer)
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))

        // -60 dB floor, then a fast-attack / slow-release smooth so the meter
        // tracks speech instead of flickering on every buffer.
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 60) / 60))
        let coefficient: Float = normalized > smoothedLevel ? 0.5 : 0.12
        smoothedLevel += (normalized - smoothedLevel) * coefficient

        let level = smoothedLevel
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    @objc private func configurationChanged(_ note: Notification) {
        guard isRecording else {
            // Idle when the device changed. The engine is still bound to the
            // one it was prepared against, so it starts happily and captures
            // nothing — a recording that produces a 0-frame file and no error.
            // Plugging in AirPods was enough to do it.
            DispatchQueue.main.async { [weak self] in self?.rebuildEngine() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.onUnexpectedStop?(nil)
        }
    }

    /// Replaces the engine so the next recording acquires the current device.
    /// Re-preparing the existing one is not enough; it keeps the old device.
    private func rebuildEngine() {
        guard !isRecording else { return }
        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: engine
        )
        engine.stop()
        engine = AVAudioEngine()
        observeConfigurationChanges()
        warmUp()
        Log.write("audio device changed; capture engine rebuilt")
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
