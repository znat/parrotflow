import Foundation

/// `--sentence-probe` — is this period real, or did a pause cut one sentence
/// in two?
///
/// The two halves of the boundary, left then right. The period on the left is
/// optional; the capital on the right is expected, because that is what the
/// transcriber writes.
///
///     ParrotFlow --sentence-probe "we have to do it." "That works well"
///       boundary  "." 15   " ." 964   "That" 2773   " That" 2064  ✓
///       text      we have to do it [MASK] that works well
///       score      -2.63          ← below -4 means the period is false
///       period     -5.71   "."
///       next       -3.08   " that"
///       top        " that" -3.08   " which" -4.10   " it" -4.87
///
/// `--encode "<text>"` prints the ids alone and loads no model, which is what
/// `scripts/check-tokenizer.sh` compares against the reference tokenizer.
@available(macOS 14, *)
enum SentenceProbeCommand {

    static func run(left: String, right: String) -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            do {
                let probe = try await SentenceProbe.load { label in
                    print("\r  \(label)…", terminator: "")
                    fflush(stdout)
                }
                print("\r\u{1B}[K", terminator: "")
                let listed = probe.tokenizer.boundaryIDs
                    .map { "\($0.token.debugDescription) \($0.id)" }
                    .joined(separator: "   ")
                print("  boundary  \(listed)  ✓")

                let reading = try probe.read(left: left, right: right)
                print("  text      \(reading.text)")
                print(row("score", reading.score, ""))
                print(row("period", reading.periodLogProbability, "\".\""))
                print(row("next", reading.nextLogProbability, reading.next.debugDescription))
                let top = reading.top
                    .map { "\($0.word.debugDescription) \(format($0.logProbability))" }
                    .joined(separator: "   ")
                print("  top       \(top)")
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
        do {
            let tokenizer = try BPETokenizer.load(contentsOf: SentenceProbe.tokenizerURL)
            let ids = tokenizer.encode(text)
            print("ids \(ids.map(String.init).joined(separator: ","))")
            print("tokens \(ids.compactMap { tokenizer.word(of: $0)?.debugDescription }.joined(separator: " "))")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    private static func row(_ name: String, _ value: Double, _ note: String) -> String {
        let padded = name + String(repeating: " ", count: max(0, 9 - name.count))
        return "  \(padded) \(format(value))   \(note)"
    }

    /// `%@` ignores a width on this platform, so the column is padded here.
    private static func format(_ value: Double) -> String {
        String(format: "%7.2f", value)
    }
}
