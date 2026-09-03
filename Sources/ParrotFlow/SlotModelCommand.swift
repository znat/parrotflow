import CoreML
import Foundation

/// `--slot-model` — fetches, compiles and loads mmBERT-small, then says what it
/// got and how long it took.
///
///     ParrotFlow --slot-model
///       slot model 43%…
///     ✓ slot model ready in 38.4s
///       cache   ~/Library/Application Support/ParrotFlow/models/mmbert-small-64
///       inputs  input_ids [1, 64]
///       outputs logits [1, 64, 256000]
///
/// The same call the first English dictation makes, without a microphone. Run
/// it twice: the second run skips the download and the compile, which is the
/// only proof the cache is being used.
///
/// `--slot-probe --encode "<text>"` is the tokenizer alone, and loads no model.
@available(macOS 14, *)
enum SlotModelCommand {

    static func run() -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            let started = Date()
            let cached = SlotModel.isCached
            do {
                let model = try await SlotModel.shared.prepare { label in
                    print("\r  \(label)…", terminator: "")
                    fflush(stdout)
                }
                let seconds = Date().timeIntervalSince(started)
                print(String(
                    format: "\r\u{1B}[K✓ slot model ready in %.1fs (%@)",
                    seconds, cached ? "cached" : "downloaded and compiled"
                ))
                print("  cache   \(tilde(SlotModel.directory.path))")
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
