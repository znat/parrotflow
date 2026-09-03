import Foundation
import MLX

/// `--sentence-probe` — is this period real, or did a pause cut one sentence
/// in two?
///
/// The two halves of the boundary, left then right. The period on the left is
/// optional; the capital on the right is expected, because that is what the
/// transcriber writes. Every reading of the boundary is scored, per token of
/// the continuation, and the highest wins.
///
///     ParrotFlow --sentence-probe "…the LLM with." "The vocabulary is slower"
///       prefix    the first usage of the LLM with
///       reading   .         -7.2669  5
///       reading   ,         -6.5327  5
///       reading   join      -4.5571  4
///       winner    join
///
/// `--encode "<text>"` prints ModernBERT's ids and loads no model, which is
/// what `scripts/check-tokenizer.sh` compares against the reference tokenizer.
/// That tokenizer is the vocabulary slot gate's, not this stage's.
///
/// `--bench <cases.json> --out <scores.json>` scores a whole file in one loaded
/// process — `[{"left": …, "right": …}]` in, one row of scores out, with the
/// milliseconds each decision took. One process per boundary would pay the 1.3s
/// load every time, so this is the only way to get a latency number. `--vectors`
/// loads the word vectors as well, so the memory line describes the process the
/// app actually runs, with both MLX models in it.
@available(macOS 14, *)
enum SentenceProbeCommand {

    static func run(left: String, right: String) -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        let marks = ((try? ConfigStore.load()) ?? Config()).transcription.sentences.marks

        Task {
            do {
                try await SentenceReadings.shared.prepare { label in
                    print("\r  \(label)…", terminator: "")
                    fflush(stdout)
                }
                print("\r\u{1B}[K", terminator: "")
                guard let built = SentenceReadings.build(
                    left: left, right: right, marks: marks
                ) else { throw SentenceReadings.Failure.empty }
                print("  prefix    \(built.prefix)")
                let scores = try await SentenceReadings.shared.read(
                    left: left, right: right, marks: marks
                )
                for score in scores {
                    // `%@` ignores a width on this platform, so the column
                    // is padded here.
                    let key = score.key.padding(toLength: 8, withPad: " ", startingAt: 0)
                    print(String(
                        format: "  reading   %@ %8.4f  %d%@",
                        key, score.mean, score.tokens,
                        score.retokenised ? "  retokenised" : ""
                    ))
                }
                print("  winner    \(SentenceJoin.winner(of: scores)?.key ?? "none")")
            } catch {
                print("\r\u{1B}[K✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }

    /// Every boundary in a file, scored in one loaded process.
    static func bench(cases path: String, out: String?, vectors: Bool) -> Int32 {
        struct Row: Decodable { let left: String; let right: String }
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        let marks = ((try? ConfigStore.load()) ?? Config()).transcription.sentences.marks

        Task {
            do {
                let rows = try JSONDecoder().decode(
                    [Row].self, from: Data(contentsOf: URL(fileURLWithPath: path))
                )
                if vectors { try await WordVectors.shared.prepare() }
                try await SentenceReadings.shared.prepare()
                var results: [[String: Any]] = []
                var times: [Double] = []
                for (i, row) in rows.enumerated() {
                    let start = DispatchTime.now().uptimeNanoseconds
                    guard let scores = try? await SentenceReadings.shared.read(
                        left: row.left, right: row.right, marks: marks
                    ) else { continue }
                    let winner = SentenceJoin.winner(of: scores)?.key ?? "none"
                    let elapsed = Double(
                        DispatchTime.now().uptimeNanoseconds - start
                    ) / 1e6
                    // The first decision pays the Metal kernel compile.
                    if i > 0 { times.append(elapsed) }
                    var means: [String: Double] = [:]
                    var tokens: [String: Int] = [:]
                    for score in scores {
                        means[score.key] = score.mean
                        tokens[score.key] = score.tokens
                    }
                    results.append([
                        "i": i, "mean": means, "n": tokens, "winner": winner,
                        "ms": elapsed,
                        "retokenised": scores.contains(where: \.retokenised),
                    ])
                }
                let data = try JSONSerialization.data(
                    withJSONObject: results, options: [.prettyPrinted, .sortedKeys]
                )
                if let out {
                    try data.write(to: URL(fileURLWithPath: out))
                } else {
                    FileHandle.standardOutput.write(data)
                }
                times.sort()
                if !times.isEmpty {
                    print(String(
                        format: "  %d boundaries   median %.1f ms   p95 %.1f ms",
                        results.count, times[times.count / 2],
                        times[min(times.count - 1, Int(Double(times.count) * 0.95))]
                    ))
                }
                print("  MLX active \(MLX.GPU.activeMemory / 1_048_576) MB"
                    + "   cache \(MLX.GPU.cacheMemory / 1_048_576) MB"
                    + "   peak \(MLX.GPU.peakMemory / 1_048_576) MB")
            } catch {
                print("✗ \(error.localizedDescription)")
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        return exitCode
    }

    /// The tokenizer of the masked model the vocabulary slot gate reads. No
    /// model, so this answers on a machine that has never run a dictation.
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
}
