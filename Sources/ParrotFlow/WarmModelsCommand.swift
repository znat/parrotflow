import Foundation

/// `--warm-models` — downloads Parakeet (and the voice detector, if the
/// config asks for one) and runs one decode, without waiting for a first
/// dictation.
///
/// `Transcriber.prepare` already downloads lazily, on the first real
/// transcription. This command calls the same method, so `install.sh` — or
/// anyone else scripting a setup — can trigger the download on its own
/// schedule instead of the user's first attempt to dictate. `warmDecode`
/// then runs the graph once, which is the other half of the first dictation's
/// cost and the half `prepare` does not cover.
enum WarmModelsCommand {

    static func run() -> Int32 {
        guard #available(macOS 14, *) else {
            print("✗ transcription needs macOS 14 or later")
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
                if case .downloading(let what, _) = status {
                    print("\r  downloading \(what)…", terminator: "")
                    fflush(stdout)
                }
            }
            do {
                try await transcriber.prepare(config: config)
                // Downloaded and loaded is not run. `install.sh` calls this so
                // the first dictation waits for nothing, and the Core ML
                // compile is part of what it would otherwise wait for.
                await transcriber.warmDecode()
                print("\r\u{1B}[K✓ models ready")
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
