import CoreML
import Foundation

/// `--sentence-model` — fetches, compiles and loads ModernBERT, then says what
/// it got and how long it took.
///
///     ParrotFlow --sentence-model
///       sentence model 43%…
///     ✓ sentence model ready in 41.2s
///       cache   ~/Library/Application Support/ParrotFlow/models/modernbert-base-64
///       inputs  input_ids [1, 64]
///       outputs logits [1, 64, 50368]
///
/// The same call the first English dictation makes, without a microphone. Run
/// it twice: the second run skips the download and the 7s compile, which is
/// the only proof the cache is being used.
@available(macOS 14, *)
enum SentenceModelCommand {

    static func run() -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            let started = Date()
            let cached = SentenceModel.isCached
            do {
                let model = try await SentenceModel.shared.prepare { label in
                    print("\r  \(label)…", terminator: "")
                    fflush(stdout)
                }
                let seconds = Date().timeIntervalSince(started)
                print(String(
                    format: "\r\u{1B}[K✓ sentence model ready in %.1fs (%@)",
                    seconds, cached ? "cached" : "downloaded and compiled"
                ))
                print("  cache   \(tilde(SentenceModel.directory.path))")
                describe("inputs ", model.modelDescription.inputDescriptionsByName)
                describe("outputs", model.modelDescription.outputDescriptionsByName)
            } catch {
                print("\r\u{1B}[K✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }

    private static func describe(
        _ title: String, _ features: [String: MLFeatureDescription]
    ) {
        for name in features.keys.sorted() {
            let shape = features[name]?.multiArrayConstraint?.shape.map(\.stringValue)
                .joined(separator: ", ")
            print("  \(title) \(name)\(shape.map { " [\($0)]" } ?? "")")
        }
    }

    private static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
