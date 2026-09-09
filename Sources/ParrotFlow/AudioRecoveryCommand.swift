import AVFoundation
import CoreAudio
import Foundation
import Yams

/// `--audio-recovery` — drives a device change past the recorder and checks it
/// comes back, without touching the machine's audio settings.
///
/// The bug in #95 is a microphone that changes underneath a running app: the
/// recorder keeps writing through the device that left, every buffer is
/// refused, and the clip is silence that nothing reports. Reproducing that for
/// real means switching the default input device, which takes the microphone
/// away from whoever is dictating — so this moves the *binding* instead.
/// `Recorder.currentInput` is the one place the recorder asks what the system
/// would hand it; replacing it is enough to make the recorder believe a headset
/// arrived, and every path below that is the real one.
///
/// What it does not cover: the hardware. No session is started here, so "the
/// buffers that arrive are the ones the new device sends" is a claim `--record`
/// has to make. See docs/cli.md.
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

        // Every check that ran, so the total below counts what was answered
        // rather than what was written.
        var results: [Bool] = []

        print("Device changes")
        results += cases.map { check($0) }

        print("")
        print("The device the list names")
        if let bound = checkTheSessionIsBoundToTheNamedDevice() { results.append(bound) }

        print("")
        thisMachine()

        print("")
        print("Capture after a device change")
        results.append(checkCaptureSurvivesTheChange(config: config))
        results.append(checkAForeignFormatIsReported(config: config))
        results.append(checkPartialLossIsRefused(config: config))
        results.append(checkOneLostBufferIsForgiven(config: config))

        let passed = results.filter { $0 }.count
        print("")
        print("  \(passed)/\(results.count)")
        return passed == results.count ? 0 : 1
    }

    /// What the recorder is on right now, and what it cost to get there.
    ///
    /// Printed, never scored. A build machine has no microphone and a laptop
    /// has whatever is plugged into it. `open` is the line to read: warming up
    /// resolves the device and builds the session, and it must not start it —
    /// the orange indicator belongs to a recording, not to a launch.
    private static func thisMachine() {
        print("This machine")
        guard let binding = Recorder.InputBinding.system() else {
            print("  no input device")
            return
        }
        // Read before as well as after: the property is system-wide, so another
        // app already holding the microphone would otherwise read as ours.
        let before = Recorder.isRunningSomewhere(binding.device)
        let recorder = Recorder()
        recorder.warmUp()
        let after = Recorder.isRunningSomewhere(binding.device)

        print("  device   \(Recorder.inputDeviceName ?? "unnamed") — \(binding.described)")
        print("  bound    \(recorder.boundDevice?.name ?? "nothing")")
        print("  capture  \(recorder.captureDeviceID ?? "no AVCaptureDevice resolved")")
        print("  open     \(after ? "yes" : "no") after warmUp"
              + " (\(before ? "already open before it" : "closed before it"))")
    }

    // MARK: - The device

    /// The recorder binds to the microphone the device list names.
    ///
    /// The binding cases below cannot reach this: their device numbers name
    /// nothing, so no capture device is ever resolved from them. Here the name
    /// comes out of CoreAudio and has to come back out of AVFoundation.
    ///
    /// Nil when the machine has no input device, which is a skip and not a
    /// failure.
    private static func checkTheSessionIsBoundToTheNamedDevice() -> Bool? {
        let name = "the session is bound to the named device"
        guard let wanted = Recorder.inputDeviceName else {
            print("  – \(name.padding(toLength: 46, withPad: " ", startingAt: 0)) no input device here")
            return nil
        }

        let recorder = Recorder()
        recorder.preferredMicrophones = [wanted]
        recorder.warmUp()

        guard let bound = recorder.boundDevice?.name else {
            return say(false, name, "nothing was bound")
        }
        guard bound == wanted else {
            return say(false, name, "bound \"\(bound)\", not \"\(wanted)\"")
        }
        guard let id = recorder.captureDeviceID else {
            return say(false, name, "no capture device answers to \"\(wanted)\"")
        }
        return say(true, name, id)
    }

    // MARK: - The decision

    /// Moves the binding under an idle recorder and checks whether it rebound.
    ///
    /// The change is delivered the way CoreAudio delivers one — a device-list
    /// change, through the listener's own body — not as a direct call to the
    /// comparison. So a change that breaks the path between the two still fails
    /// the check.
    private static func check(_ testCase: Case) -> Bool {
        let recorder = Recorder()
        recorder.currentInput = { testCase.from }
        recorder.warmUp()

        let before = recorder.rebuilds
        recorder.currentInput = { testCase.to }
        recorder.simulateDeviceListChange()

        // The change hops to the main queue, which needs the run loop to turn.
        // Two seconds is well over what a rebind costs and well under a timeout
        // that would make a red result ambiguous.
        settle(untilTrue: { recorder.rebuilds > before }, seconds: 2)

        let rebuilt = recorder.rebuilds > before
        guard rebuilt == testCase.rebuild else {
            print("  ✗ \(testCase.name)")
            print("      got   \(rebuilt ? "rebound" : "no rebind")")
            print("      want  \(testCase.rebuild ? "rebound" : "no rebind") — \(testCase.why)")
            return false
        }
        let padded = testCase.name.padding(toLength: 46, withPad: " ", startingAt: 0)
        print("  ✓ \(padded) \(rebuilt ? "rebound" : "left alone")")
        return true
    }

    // MARK: - The capture

    /// #95's acceptance criterion, one level under the hardware: after a
    /// simulated switch, the capture path writes a real signal.
    ///
    /// The change is the one from #95 — the same device at a new rate, which is
    /// what a headset does while its link settles — so the rebind has to fire
    /// for this to get as far as measuring anything. The buffers are a 440 Hz
    /// tone rather than a microphone, so what is measured after that is the
    /// write. It has to come out with non-trivial RMS.
    private static func checkCaptureSurvivesTheChange(config: Config) -> Bool {
        let name = "a tone at the new rate is written"
        let settling = Recorder.InputBinding(device: 2, sampleRate: 48000, channels: 1)
        let settled = Recorder.InputBinding(device: 2, sampleRate: 24000, channels: 1)

        let recorder = Recorder()
        recorder.currentInput = { settling }
        recorder.warmUp()

        recorder.currentInput = { settled }
        recorder.simulateDeviceListChange()
        settle(untilTrue: { recorder.rebuilds > 0 }, seconds: 2)

        guard recorder.rebuilds > 0 else {
            print("  ✗ \(name)")
            print("      got   the format change was ignored, so the session stayed where it was")
            print("      want  a rebind, then a clip with signal in it")
            return false
        }

        guard let good = format(config.audio.sampleRate) else {
            return say(false, name, "could not build the format")
        }

        do {
            try recorder.openCapture(config: config, markRecording: true)
        } catch {
            return say(false, name, error.localizedDescription)
        }
        for _ in 0..<20 { recorder.process(buffer: tone(good, frames: 4096)) }
        pause(overTheFloor)

        guard let recording = recorder.stop(config: config) else {
            return say(false, name, "nothing was written")
        }
        defer { try? FileManager.default.removeItem(at: recording.url) }

        guard recording.rms >= Recorder.silenceFloor else {
            print("  ✗ \(name)")
            print(String(format: "      got   rms %.5f", recording.rms))
            print(String(format: "      want  at least %.5f", Recorder.silenceFloor))
            return false
        }
        return say(true, name, String(format: "rms %.3f", recording.rms))
    }

    /// The safety net from #95, without the converter that used to be it.
    ///
    /// Buffers at a rate the open file cannot take. AVCapture is asked for one
    /// format and delivers it, so nothing should reach this in the app — and
    /// when something does, it is audio that was spoken and is not on disk.
    /// Nothing must be written, and the recorder must say so rather than
    /// returning nil in silence.
    private static func checkAForeignFormatIsReported(config: Config) -> Bool {
        let name = "a foreign format is reported, not swallowed"
        guard let foreign = format(24000) else {
            return say(false, name, "could not build the format")
        }

        let recorder = Recorder()
        var reported: String?
        recorder.onCaptureProblem = { reported = $0 }
        // No device at either end, so stopping does not send this recorder off
        // to bind to whatever the machine is really plugged into.
        recorder.currentInput = { nil }

        do {
            try recorder.openCapture(config: config, markRecording: true)
        } catch {
            return say(false, name, error.localizedDescription)
        }
        for _ in 0..<20 { recorder.process(buffer: tone(foreign, frames: 4096)) }
        pause(overTheFloor)

        let recording = recorder.stop(config: config)
        settle(untilTrue: { reported != nil }, seconds: 2)

        if let recording {
            try? FileManager.default.removeItem(at: recording.url)
            print("  ✗ \(name)")
            print(String(format: "      got   a clip at rms %.5f", recording.rms))
            print("      want  nothing, because every buffer was refused")
            return false
        }
        guard let reported else {
            print("  ✗ \(name)")
            print("      got   nothing said")
            print("      want  a message through onCaptureProblem")
            return false
        }
        return say(true, name, "\"\(reported)\"")
    }

    /// How much audio one refused buffer below is worth: 4096 frames at 24 kHz,
    /// 171 ms, whatever rate it would have been resampled to. Worked out here
    /// from the buffer rather than read off the recorder, so the expected number
    /// and the measured one come from different places.
    private static let lostPerBuffer: Double = 4096 / 24000

    /// A recording that lost more than `droppedAudioTolerance` is not handed on.
    ///
    /// Good buffers first, then buffers in a format the file cannot take — a
    /// device that changed halfway through a sentence. What is on disk is the
    /// first half. Transcribing it would type half a sentence with nothing to
    /// say which half is missing.
    private static func checkPartialLossIsRefused(config: Config) -> Bool {
        let buffers = 8
        let name = String(
            format: "a clip that lost %.2fs is not transcribed",
            Double(buffers) * lostPerBuffer
        )
        let outcome = recordThenLose(buffers: buffers, config: config)
        if let recording = outcome.recording {
            try? FileManager.default.removeItem(at: recording.url)
            return say(false, name, "it was handed on anyway")
        }
        guard let reported = outcome.reported else {
            return say(false, name, "nothing was said")
        }
        return say(true, name, "\"\(reported)\"")
    }

    /// And one that lost a single buffer still is — but says so.
    ///
    /// This is the ordinary headset disconnect. The recording is stopped by the
    /// device change, and one buffer can arrive in the new format before that
    /// stop reaches the main queue. Every word is in the part that was written,
    /// so refusing the clip would cost the whole dictation to save nothing.
    ///
    /// Both halves are checked, because passing the clip on *quietly* is its own
    /// bug: the sentence arrives a syllable short with nothing saying so.
    private static func checkOneLostBufferIsForgiven(config: Config) -> Bool {
        let name = String(
            format: "a clip that lost %.2fs is transcribed and said", lostPerBuffer
        )
        let outcome = recordThenLose(buffers: 1, config: config)
        guard let recording = outcome.recording else {
            return say(false, name, "it was refused")
        }
        try? FileManager.default.removeItem(at: recording.url)
        guard recording.rms >= Recorder.silenceFloor else {
            return say(false, name, String(format: "rms %.5f", recording.rms))
        }
        guard let reported = outcome.reported else {
            return say(false, name, "it was handed on with nothing said about the loss")
        }
        return say(true, name, "\"\(reported)\"")
    }

    /// Twenty good buffers, then `buffers` in a format the file refuses.
    private static func recordThenLose(
        buffers: Int, config: Config
    ) -> (recording: Recorder.Recording?, reported: String?) {
        guard let good = format(config.audio.sampleRate), let foreign = format(24000) else {
            return (nil, nil)
        }

        let recorder = Recorder()
        var reported: String?
        recorder.onCaptureProblem = { reported = $0 }
        recorder.currentInput = { nil }

        guard (try? recorder.openCapture(config: config, markRecording: true)) != nil else {
            return (nil, nil)
        }
        for _ in 0..<20 { recorder.process(buffer: tone(good, frames: 4096)) }
        for _ in 0..<buffers { recorder.process(buffer: tone(foreign, frames: 4096)) }
        pause(overTheFloor)

        let recording = recorder.stop(config: config)
        settle(untilTrue: { reported != nil }, seconds: 1)
        return (recording, reported)
    }

    private static func say(_ ok: Bool, _ name: String, _ detail: String) -> Bool {
        let padded = name.padding(toLength: 46, withPad: " ", startingAt: 0)
        print("  \(ok ? "✓" : "✗") \(padded) \(detail)")
        return ok
    }

    // MARK: - Helpers

    private static func format(_ rate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        )
    }

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

    /// Let the wall clock past `min_duration_seconds`, which is what `stop`
    /// measures a clip by.
    ///
    /// The buffers in the checks above are pushed through in microseconds, so a
    /// clip made of twenty of them is seconds of audio and no time at all.
    /// `stop` reads the clock, calls that shorter than the floor, and returns
    /// nil. It is the harness that has to wait, not the recorder that has to
    /// count frames: the floor exists to throw away a key pressed and released,
    /// and that is a question about time.
    private static func pause(_ seconds: TimeInterval) {
        settle(untilTrue: { false }, seconds: seconds)
    }

    /// Comfortably over the 0.3s floor.
    private static let overTheFloor: TimeInterval = 0.4

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
