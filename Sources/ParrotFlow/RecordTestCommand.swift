import AVFoundation
import Foundation

/// `--record [seconds]` — records straight from the terminal, no hotkey and no
/// menu bar, and prints what landed on disk. The fastest way to answer "is the
/// microphone actually reaching this app?".
enum RecordTestCommand {

    static func run(seconds: Double) -> Int32 {
        let config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        guard Permissions.microphone == .granted else {
            print("✗ microphone permission not granted (\(Permissions.microphone.label))")
            print("  Launch ParrotFlow.app once and allow it, then try again.")
            return 1
        }

        let recorder = Recorder()
        // Before `warmUp`, which is what opens the device. The whole point of
        // this command is to record through what the app would record through.
        recorder.preferredMicrophones = config.audio.microphones
        recorder.warmUp()
        var peak: Float = 0
        recorder.onLevel = { peak = max(peak, $0) }

        // Stands in for the hotkey press: the app measures from the key going
        // down, and the question is the same one — how much of what follows is
        // said before anything is recording.
        let pressed = Date()
        do {
            let url = try recorder.start(config: config)
            print("● recording \(seconds)s → \(url.lastPathComponent)")
            // Which microphone this went through, which is the question when
            // the clip comes back silent and the list has an entry in it.
            print("  through    \(recorder.boundDevice?.name ?? "unknown device")")
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }

        // AVAudioEngine delivers tap buffers on the run loop's behalf.
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))

        guard let recording = recorder.stop(config: config) else {
            print("✗ nothing written (shorter than min_duration_seconds?)")
            return 1
        }

        return report(recording: recording, peak: peak, config: config, pressed: pressed)
    }

    private static func report(
        recording: Recorder.Recording, peak: Float, config: Config, pressed: Date
    ) -> Int32 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: recording.url.path)
        let bytes = (attributes?[.size] as? Int) ?? 0

        print("✓ wrote \(recording.url.path)")
        print("  duration   \(String(format: "%.2f", recording.duration))s")
        // The gap this prints is speech that would have been lost. `start`
        // returns as soon as the graph runs; the device sends when it is ready.
        if let first = recording.firstSampleAt {
            print("  waited     \(String(format: "%.0f", first.timeIntervalSince(pressed) * 1000)) ms for the first sample")
        }
        print("  size       \(bytes) bytes")
        // The same number the app judges a clip by, so what this prints and
        // what the menu bar would warn about are one measurement.
        print("  rms        \(String(format: "%.5f", recording.rms))"
              + (recording.rms < Recorder.silenceFloor ? "  — silence" : ""))

        guard let file = try? AVAudioFile(forReading: recording.url) else {
            print("✗ the file is not readable as audio")
            return 1
        }
        let format = file.fileFormat
        print("  format     \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(bitDepth(of: format))-bit")
        print("  frames     \(file.length)")

        var ok = true

        if format.sampleRate != config.audio.sampleRate || format.channelCount != 1 {
            print("✗ expected \(Int(config.audio.sampleRate)) Hz mono")
            ok = false
        }

        // A silent file usually means the grant went to the wrong binary, or
        // something else has the input device.
        if peak < 0.02 {
            print("✗ signal is silent (peak \(String(format: "%.3f", peak))) — check the input device")
            ok = false
        } else {
            print("  peak level \(String(format: "%.2f", peak))")
        }

        // 16 kHz mono 16-bit ≈ 32000 bytes/s. Well under that means dropped audio.
        let expected = recording.duration * config.audio.sampleRate * 2
        if Double(bytes) < expected * 0.8 {
            print("✗ file is smaller than expected for its duration — buffers were dropped")
            ok = false
        }

        return ok ? 0 : 1
    }

    private static func bitDepth(of format: AVAudioFormat) -> Int {
        Int(format.streamDescription.pointee.mBitsPerChannel)
    }
}
