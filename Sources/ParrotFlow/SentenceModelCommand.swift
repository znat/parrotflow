import Foundation

/// `--sentence-model` — fetches the model the boundary readings are scored
/// with, then says what it got and how long it took.
///
///     ParrotFlow --sentence-model
///       sentence readings 43%…
///     ✓ sentence readings ready in 22.4s (downloaded)
///       cache   ~/Library/Application Support/ParrotFlow/models/qwen3-0.6b-base-4bit
///
/// The same call the first English dictation makes, without a microphone. Run
/// it twice: the second run skips the download, which is the only proof the
/// cache is being used.
///
/// The vocabulary slot gate has its own model and its own command,
/// `--slot-model`.
@available(macOS 14, *)
enum SentenceModelCommand {

    static func run() -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            let readingsStarted = Date()
            let readingsCached = SentenceReadings.isCached
            do {
                try await SentenceReadings.shared.prepare { label in
                    print("\r  \(label)…", terminator: "")
                    fflush(stdout)
                }
                print(String(
                    format: "\r\u{1B}[K✓ sentence readings ready in %.1fs (%@)",
                    Date().timeIntervalSince(readingsStarted),
                    readingsCached ? "cached" : "downloaded"
                ))
                print("  cache   \(tilde(SentenceReadings.directory.path))")
            } catch {
                print("\r\u{1B}[K✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }

    private static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
