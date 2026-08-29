import Foundation

/// `--sentence-probe` — what ModernBERT would put in one slot of a sentence.
///
/// Write the slot as `[MASK]`. The top ten words come back, most likely first:
///
///     ParrotFlow --sentence-probe "The capital of Ireland is [MASK]."
///       boundary  "." 15   " ." 964   "That" 2773   " That" 2064   ✓
///       mask at 6 of 64
///        1   Dublin           -0.19
///        2   Belfast          -3.02
///
/// That sentence is the acceptance test for the model itself. The published
/// repository exists to warn about a conversion that reads only one token, and
/// a broken one answers `£, isation, organisation, ised` here. If you get that
/// list, the tokenizer or the packing is wrong, not the model.
///
/// The `boundary` line is the tokenizer's own assertion, run at load against a
/// real tokenization of `"we have to do it. That works well"`. It is printed
/// because the mistake it catches is silent: a word after another word carries
/// its leading space, so `" That"` is 2064 and `"That"` is 2773, and a caller
/// comparing against the second scores zero without erroring.
///
/// `--against` asks the other question: how likely one named token is here,
/// beside the period. That is the sentence-join shape, and it answers whether
/// a pause that ended a sentence should have.
///
///     ParrotFlow --sentence-probe "the report is due on [MASK] morning" --against " Friday"
///       " Friday"         -2.43        the cut was spurious, join it
///       period            -7.71
///
///     ParrotFlow --sentence-probe "we have to do it [MASK] works well" --against " That"
///       " That"           -8.20        the period is real, leave it
///       period            -4.35
///
/// The period is the better of `.` and `Ġ.`, because the slot can be reached
/// either way. Write the leading space in `--against`.
///
/// One forward pass either way, about 8 ms once the model is loaded. The first
/// run downloads 300 MB and compiles it, which is `--sentence-model`.
@available(macOS 14, *)
enum SentenceProbeCommand {

    private static let marker = "[MASK]"

    static func run(text: String, against candidate: String?, top: Int = 10) -> Int32 {
        guard let cut = text.range(of: marker) else {
            print("usage: ParrotFlow --sentence-probe \"… \(marker) …\" [--against \" word\"]")
            return 2
        }
        // The mask stands for the token including its leading space, so the
        // one space a person writes before `[MASK]` is the mask's own and is
        // dropped. Without this the slot gets a bare word and the answers
        // quietly get worse.
        var left = String(text[..<cut.lowerBound])
        if left.hasSuffix(" ") { left.removeLast() }
        let right = String(text[cut.upperBound...])

        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)

        Task {
            do {
                let probe = try await SentenceProbe.load { label in
                    print("\r  \(label)…", terminator: "")
                    fflush(stdout)
                }
                print("\r\u{1B}[K", terminator: "")
                report(probe.tokenizer.boundaryIDs)

                let first = Date()
                let slot = try probe.at(left: left, right: right)
                let cold = Date().timeIntervalSince(first) * 1000
                // The same pass again. Core ML spends the first prediction
                // warming, so a single reading says nothing about what a
                // caller making one of these per window will pay.
                let second = Date()
                _ = try probe.at(left: left, right: right)
                let warm = Date().timeIntervalSince(second) * 1000

                print("  mask at \(slot.position) of \(SentenceProbe.length)")
                if let candidate, !candidate.isEmpty {
                    say(candidate.debugDescription, probe.tokenizer.firstID(of: candidate), slot)
                    // Both spellings, because the slot the mask stands for can
                    // be reached with a space or without one, and the caller
                    // wants the better of the two.
                    let period = [".", " ."].compactMap { probe.tokenizer.firstID(of: $0) }
                        .map { slot.logProbability(of: $0) }.max() ?? -.infinity
                    print(column("period", period))
                } else {
                    for (rank, guess) in slot.top(top).enumerated() {
                        print("  \(pad("\(rank + 1)", 2, left: false))" + column(guess.word, guess.logProbability))
                    }
                }
                print(String(format: "  one forward pass, %.0f ms warm, %.0f ms on the first", warm, cold))
            } catch {
                print("\r\u{1B}[K✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }

    private static func say(_ token: String, _ id: Int?, _ slot: SentenceProbe.Slot) {
        guard let id else {
            print("  \(token) does not encode")
            return
        }
        print(column(token, slot.logProbability(of: id)))
    }

    /// `%@` ignores a width on this platform, so the columns are padded here.
    private static func column(_ token: String, _ score: Double) -> String {
        "  " + pad(token, 16) + String(format: "%7.2f", score)
    }

    private static func pad(_ text: String, _ width: Int, left: Bool = true) -> String {
        let room = String(repeating: " ", count: max(0, width - text.count))
        return left ? text + room : room + text
    }

    private static func report(_ ids: [(token: String, id: Int)]) {
        let listed = ids.map { "\($0.token.debugDescription) \($0.id)" }.joined(separator: "   ")
        print("  boundary  \(listed)   ✓")
    }
}
