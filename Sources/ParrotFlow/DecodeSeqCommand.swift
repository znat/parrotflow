import Foundation
import FluidAudio

/// TEMPORARY experiment. `--decode-seq [--parallel] [--repeat N] a.wav b.wav …`
///
/// Decodes the clips straight through `AsrManager`, with a fresh
/// `TdtDecoderState` each, and prints the wall clock. Nothing else in the app
/// is involved — no speech gate, no pipeline, no retry.
///
/// `--parallel` gives each clip its own `AsrManager` and runs them in a task
/// group. `AsrManager` is an actor, so one instance would serialise the calls
/// however they were issued; the models behind them are shared.
///
/// Delete once the answer is written down.
enum DecodeSeqCommand {

    static func run(paths: [String], parallel: Bool, repeatCount: Int) -> Int32 {
        guard #available(macOS 14, *) else {
            print("✗ needs macOS 14 or later")
            return 1
        }

        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            do {
                let models = try await AsrModels.downloadAndLoad()
                let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                    print("✗ no such file: \(url.path)")
                    exitCode = 1
                }
                guard exitCode == 0 else { done.signal(); return }

                // One warm pass before timing: the first decode after load
                // pays for lazy CoreML setup and would otherwise land on
                // whichever arm ran first.
                let warm = AsrManager(models: models)
                var warmState = await TdtDecoderState.make(decoderLayers: warm.decoderLayerCount)
                _ = try await warm.transcribe(urls[0], decoderState: &warmState)

                for round in 1...max(1, repeatCount) {
                    let start = Date()
                    var texts: [String] = []

                    if parallel {
                        texts = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                            for (i, url) in urls.enumerated() {
                                group.addTask {
                                    let m = AsrManager(models: models)
                                    var s = await TdtDecoderState.make(
                                        decoderLayers: m.decoderLayerCount
                                    )
                                    let r = try await m.transcribe(url, decoderState: &s)
                                    return (i, r.text)
                                }
                            }
                            var out = Array(repeating: "", count: urls.count)
                            for try await (i, t) in group { out[i] = t }
                            return out
                        }
                    } else {
                        let m = AsrManager(models: models)
                        for url in urls {
                            var s = await TdtDecoderState.make(decoderLayers: m.decoderLayerCount)
                            texts.append(try await m.transcribe(url, decoderState: &s).text)
                        }
                    }

                    let ms = Date().timeIntervalSince(start) * 1000
                    print(String(
                        format: "round %d  %@  %d clip(s)  %.0f ms",
                        round, parallel ? "parallel  " : "sequential", urls.count, ms
                    ))
                    if round == 1 {
                        for (i, t) in texts.enumerated() {
                            print("    \(i + 1). \(t.isEmpty ? "(empty)" : t)")
                        }
                    }
                }
            } catch {
                print("✗ \(error)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }
}
