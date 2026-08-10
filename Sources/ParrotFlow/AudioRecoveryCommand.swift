import AVFoundation
import CoreAudio
import Foundation
import Yams

/// `--audio-recovery` — drives a device change past the recorder and checks it
/// comes back, without touching the machine's audio settings.
///
/// The bug in #95 is a microphone that changes underneath a running app: the
/// engine keeps converting from the format the old device was running at, every
/// buffer is refused, and the clip is silence that nothing reports. Reproducing
/// that for real means switching the default input device, which takes the
/// microphone away from whoever is dictating — so this moves the *binding*
/// instead. `Recorder.currentInput` is the one place the recorder asks what the
/// system would hand it; replacing it is enough to make the recorder believe a
/// headset arrived, and every path below that is the real one.
///
/// What it does not cover: the hardware. No input device is opened here, so
/// "the buffers that arrive are the ones the new device sends" is still a claim
/// a human has to check. See docs/cli.md.
enum AudioRecoveryCommand {

    /// One line of `tests/audio-recovery-cases.yaml`.
    private struct Case {
        let name: String
        let from: Recorder.InputBinding?
        let to: Recorder.InputBinding?
        let rebuild: Bool
        let why: String
    }

    static func run(casesPath: String?) -> Int32 {
        let config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        let path = casesPath ?? defaultCasesPath()
        let cases: [Case]
        do {
            cases = try loadCases(at: path)
        } catch {
            print("✗ cases: \(error.localizedDescription)")
            return 1
        }

        var failures = 0

        print("Device changes")
        for testCase in cases {
            failures += check(testCase) ? 0 : 1
        }

        print("")
        thisMachine()

        print("")
        print("Capture after a device change")
        failures += checkCaptureSurvivesTheChange(config: config) ? 0 : 1
        failures += checkStaleFormatIsReported(config: config) ? 0 : 1

        print("")
        if failures == 0 {
            print("  \(cases.count + 2)/\(cases.count + 2)")
            return 0
        }
        print("  \(cases.count + 2 - failures)/\(cases.count + 2)")
        return 1
    }

    /// What the two sides of the comparison say about the microphone in front
    /// of you right now.
    ///
    /// Printed, never scored. A build machine has no microphone and a laptop
    /// has whatever is plugged into it, so there is no number here to pass or
    /// fail — but if a device ever makes the engine and the stream disagree
    /// while everything is healthy, this is the line that says so, and it is
    /// the first thing to paste into an issue about a silent recording.
    private static func thisMachine() {
        print("This machine")
        guard let binding = Recorder.InputBinding.system() else {
            print("  no input device")
            return
        }
        // Held in a local, not asked of a temporary: an input node outlives
        // nothing, and reading the format off an engine that is already being
        // released segfaults. No engine is started, so the microphone
        // indicator stays off — the same promise `Recorder.warmUp` makes.
        let engine = AVAudioEngine()
        let engineFormat = engine.inputNode.outputFormat(forBus: 0)
        print("  device   \(Recorder.inputDeviceName ?? "unnamed") — \(binding.described)")
        print("  engine   \(Int(engineFormat.sampleRate)) Hz, \(engineFormat.channelCount) ch")
        print(
            "  agree    "
            + (engineFormat.sampleRate == binding.sampleRate
               ? "yes"
               : "NO — a press would rebuild the engine before recording")
        )
    }

    // MARK: - The decision

    /// Moves the binding under an idle recorder and checks whether it rebuilt.
    ///
    /// The change is delivered as the notification the engine posts, not as a
    /// direct call, so the observer has to have been moved onto each new engine
    /// for the second case in a row to be seen at all.
    private static func check(_ testCase: Case) -> Bool {
        let recorder = Recorder()
        recorder.currentInput = { testCase.from }
        recorder.warmUp()

        let before = recorder.rebuilds
        recorder.currentInput = { testCase.to }
        recorder.simulateConfigurationChange()

        // The notification hops to the main queue and the rebuild runs on its
        // own; both need the run loop to turn. Two seconds is well over the
        // 0.1s a settled device costs and well under the timeout that would
        // make a red result ambiguous.
        settle(untilTrue: { recorder.rebuilds > before }, seconds: 2)

        let rebuilt = recorder.rebuilds > before
        guard rebuilt == testCase.rebuild else {
            print("  ✗ \(testCase.name)")
            print("      got   \(rebuilt ? "rebuilt" : "no rebuild")")
            print("      want  \(testCase.rebuild ? "rebuilt" : "no rebuild") — \(testCase.why)")
            return false
        }
        print("  ✓ \(testCase.name.padding(toLength: 46, withPad: " ", startingAt: 0)) \(rebuilt ? "rebuilt" : "left alone")")
        return true
    }

    // MARK: - The capture

    /// #95's acceptance criterion, one level under the hardware: after a
    /// simulated switch, the capture path converts and writes a real signal.
    ///
    /// The change is the one from #95 — the same device at a new rate, which is
    /// what a headset does while its link settles — so the rebuild has to fire
    /// for this to get as far as measuring anything. The buffers are a 440 Hz
    /// tone rather than a microphone, so what is measured after that is the
    /// conversion and the write: the half that was silently dropping
    /// everything. It has to come out with non-trivial RMS.
    private static func checkCaptureSurvivesTheChange(config: Config) -> Bool {
        let settling = Recorder.InputBinding(device: 2, sampleRate: 48000, channels: 1)
        let settled = Recorder.InputBinding(device: 2, sampleRate: 24000, channels: 1)

        let recorder = Recorder()
        recorder.currentInput = { settling }
        recorder.warmUp()

        recorder.currentInput = { settled }
        recorder.simulateConfigurationChange()
        settle(untilTrue: { recorder.rebuilds > 0 }, seconds: 2)

        guard recorder.rebuilds > 0 else {
            print("  ✗ a tone at the new rate is written")
            print("      got   the format change was ignored, so the engine still holds 48000 Hz")
            print("      want  a rebuild, then a clip with signal in it")
            return false
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: settled.sampleRate,
            channels: AVAudioChannelCount(settled.channels), interleaved: false
        ) else {
            print("  ✗ a tone at the new rate is written  — could not build the format")
            return false
        }

        do {
            try recorder.openCapture(inputFormat: format, config: config, markRecording: true)
        } catch {
            print("  ✗ a tone at the new rate is written  — \(error.localizedDescription)")
            return false
        }
        for _ in 0..<20 { recorder.process(buffer: tone(format, frames: 4096)) }

        guard let recording = recorder.stop(config: config) else {
            print("  ✗ a tone at the new rate is written  — nothing was written")
            return false
        }
        defer { try? FileManager.default.removeItem(at: recording.url) }

        guard recording.rms >= Recorder.silenceFloor else {
            print("  ✗ a tone at the new rate is written")
            print(String(format: "      got   rms %.5f", recording.rms))
            print(String(format: "      want  at least %.5f", Recorder.silenceFloor))
            return false
        }
        print(String(
            format: "  ✓ %@ rms %.3f",
            "a tone at the new rate is written".padding(toLength: 46, withPad: " ", startingAt: 0),
            recording.rms
        ))
        return true
    }

    /// The bug itself, and the fact that it is no longer silent.
    ///
    /// A converter built from the format the *old* device was running at, handed
    /// buffers at the new one. `AVAudioConverter` reports an error and still
    /// hands back the right number of zeroed frames, so a length check cannot
    /// see it — this is what wrote the empty clips in #95. Nothing must be
    /// written, and the recorder must say so rather than returning nil in
    /// silence.
    private static func checkStaleFormatIsReported(config: Config) -> Bool {
        guard let stale = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        ), let live = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false
        ) else {
            print("  ✗ a stale format is reported, not swallowed  — could not build the formats")
            return false
        }

        let recorder = Recorder()
        var reported: String?
        recorder.onCaptureProblem = { reported = $0 }
        // No device at either end, so stopping does not send this recorder off
        // to rebuild against whatever the machine is really plugged into. What
        // is under test here is the conversion, not the acquisition.
        recorder.currentInput = { nil }

        do {
            try recorder.openCapture(inputFormat: stale, config: config, markRecording: true)
        } catch {
            print("  ✗ a stale format is reported, not swallowed  — \(error.localizedDescription)")
            return false
        }
        for _ in 0..<20 { recorder.process(buffer: tone(live, frames: 4096)) }

        let recording = recorder.stop(config: config)
        settle(untilTrue: { reported != nil }, seconds: 2)

        if let recording {
            try? FileManager.default.removeItem(at: recording.url)
            print("  ✗ a stale format is reported, not swallowed")
            print(String(format: "      got   a clip at rms %.5f", recording.rms))
            print("      want  nothing, because the converter refused every buffer")
            return false
        }
        guard let reported else {
            print("  ✗ a stale format is reported, not swallowed")
            print("      got   nothing said")
            print("      want  a message through onCaptureProblem")
            return false
        }
        print("  ✓ \("a stale format is reported, not swallowed".padding(toLength: 46, withPad: " ", startingAt: 0)) \"\(reported)\"")
        return true
    }

    // MARK: - Helpers

    /// A 440 Hz tone at a third of full scale — loud enough that no floor in
    /// the app could mistake it for a room.
    private static func tone(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        // The format is built above with a channel count of at least one, so
        // the buffer and its float data are there.
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                channel[i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / Float(format.sampleRate))
            }
        }
        return buffer
    }

    /// Turns the run loop until the condition holds or the time is up.
    private static func settle(untilTrue condition: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Cases

    private static func defaultCasesPath() -> String {
        // Beside the binary when it is run out of .build, and beside the repo
        // otherwise — the same shape the other check scripts assume.
        FileManager.default.currentDirectoryPath + "/tests/audio-recovery-cases.yaml"
    }

    private static func loadCases(at path: String) throws -> [Case] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let raw = try YAMLDecoder().decode([RawCase].self, from: text)
        return raw.map {
            Case(
                name: $0.name,
                from: binding($0.from),
                to: binding($0.to),
                rebuild: $0.rebuild,
                why: $0.why
            )
        }
    }

    private struct RawCase: Decodable {
        let name: String
        let from: RawBinding?
        let to: RawBinding?
        let rebuild: Bool
        let why: String
    }

    private struct RawBinding: Decodable {
        let device: UInt32
        let rate: Double
        let channels: UInt32
    }

    private static func binding(_ raw: RawBinding?) -> Recorder.InputBinding? {
        raw.map {
            Recorder.InputBinding(
                device: AudioDeviceID($0.device), sampleRate: $0.rate, channels: $0.channels
            )
        }
    }
}
