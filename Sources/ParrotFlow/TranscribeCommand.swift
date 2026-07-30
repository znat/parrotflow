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

        let terms = config.transcription.vocabulary
        if terms.isEmpty {
            print("vocabulary: none configured")
        } else {
            print("vocabulary: \(terms.count) terms")
            for term in terms {
                let aliases = term.aliases.isEmpty ? "" : "  ← \(term.aliases.joined(separator: ", "))"
                print("  \(term.text)\(aliases)")
            }
        }
        print("")

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

                let started = Date()
                let text = try await transcriber.transcribe(url: url, config: config)
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

                // Did the vocabulary actually land?
                // A boosted term is usually rewritten by `replacements` before
                // it reaches us, so check the canonical form too.
                let hits = terms.filter { term in
                    let canonical = config.transcription.replacements[term.text] ?? term.text
                    return text.localizedCaseInsensitiveContains(term.text)
                        || text.localizedCaseInsensitiveContains(canonical)
                }
                if !terms.isEmpty {
                    print("vocabulary hits: \(hits.isEmpty ? "none" : hits.map(\.text).joined(separator: ", "))")
                }
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
