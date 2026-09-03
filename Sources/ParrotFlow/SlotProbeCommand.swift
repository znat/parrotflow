import Foundation

/// `--slot-probe` — what words does this position expect?
///
/// The two halves of the slot, left then right. The left ends on a word, the
/// right carries its own leading space, and the mask stands for everything
/// between them.
///
///     ParrotFlow --slot-probe "The old house looked" " in the fog."
///       text      The old house looked [MASK] in the fog.
///       top       " grey" " like" " deserted" " good" " lost" …
///       call      15 ms, warm
///
/// `--encode "<text>"` prints the ids alone and loads no model, which is what
/// `scripts/check-slot-tokenizer.sh` compares against the reference tokenizer.
@available(macOS 14, *)
enum SlotProbeCommand {

    static func run(left: String, right: String) -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            do {
                let probe = try await SlotProbe.load { label in
                    print("\r  \(label)…", terminator: "")
                    fflush(stdout)
                }
                print("\r\u{1B}[K", terminator: "")
                // Twice, and the second one is reported. The first call pays
                // for Core ML's own warm-up, which is not what a dictation
                // pays.
                _ = try probe.at(left: left, right: right)
                let started = Date()
                let slot = try probe.at(left: left, right: right)
                let words = slot.top(10)
                let milliseconds = Date().timeIntervalSince(started) * 1000
                print("  text      \(left) [MASK]\(right)")
                print("  top       \(words.map(\.debugDescription).joined(separator: " "))")
                print(String(format: "  call      %.0f ms, warm", milliseconds))
            } catch {
                print("\r\u{1B}[K✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }

    /// The tokenizer on its own. No model, so this answers on a machine that
    /// has never run a dictation.
    static func encode(_ text: String) -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            do {
                let tokenizer = try await SlotTokenizer.load(from: SlotModel.tokenizerDirectory)
                let ids = tokenizer.encode(text)
                let tokens = ids.compactMap { tokenizer.word(of: $0)?.debugDescription }
                print("ids \(ids.map(String.init).joined(separator: ","))")
                print("tokens \(tokens.joined(separator: " "))")
            } catch {
                print("✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }
}
