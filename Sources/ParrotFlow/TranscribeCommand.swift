import AVFoundation
import Foundation

/// `--transcribe <file.wav>` — runs the full transcription path from the
/// terminal, which is the only practical way to iterate on vocabulary terms:
/// change the YAML, re-run, see whether the name came out right.
enum TranscribeCommand {

    static func run(path: String) -> Int32 {
        guard #available(macOS 14, *) else {
            print("✗ transcription needs macOS 14 or later")
            return 1
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("✗ no such file: \(url.path)")
            return 1
        }

        let config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            let transcriber = Transcriber { status in
                if case .downloading(let what) = status {
                    // \r keeps the download on one line instead of scrolling.
                    print("\r  downloading \(what)…", terminator: "")
                    fflush(stdout)
                }
            }
            do {
                // Separate model loading from inference — the first run
                // includes a ~1 GB download and would otherwise look like a
                // catastrophically slow transcription.
                let loadStart = Date()
                try await transcriber.prepare(config: config)
                let loadElapsed = Date().timeIntervalSince(loadStart)

                // Traced like a real dictation, marked `cli` so a sweep over
                // the archive can be told apart from what was actually spoken.
                // This is the path that makes the trace worth having: re-run
                // the recordings after a change and the two sets of numbers sit
                // in the same file, joined to the same clips.
                Trace.directory = config.resolvedOutputDir
                let started = Date()
                let text = try await Trace.record(
                    wav: url.lastPathComponent, source: .cli
                ) {
                    let text = try await transcriber.transcribe(url: url, config: config)
                    Trace.current?.recordFinal(text)
                    return text
                }
                let elapsed = Date().timeIntervalSince(started)

                print("\r\u{1B}[K", terminator: "")
                print("── transcript ─────────────────────────────")
                print(text.isEmpty ? "(empty)" : text)
                print("───────────────────────────────────────────")
                let audio = try? AVAudioFile(forReading: url)
                let duration = audio.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                print(String(format: "model load  %.2fs", loadElapsed))
                print(String(format: "transcribe  %.2fs  (%.1fs audio → %.0fx realtime)",
                             elapsed, duration, duration / max(elapsed, 0.001)))

            } catch {
                print("\r\u{1B}[K✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }
}
