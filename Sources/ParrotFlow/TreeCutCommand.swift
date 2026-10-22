import Foundation

/// `--tree-cut "<text>"` prints the filler view, each tree-cutter candidate
/// with its P(real) and whether the cut filter keeps it, then the output.
///
/// `--tree-cut --batch <items.json>` reads `[{"id", "text"}]` and prints one
/// JSON line per item, then a summary line. `--threshold <x>` replaces the
/// cut filter's own threshold.
enum TreeCutCommand {

    static func run(text: String, threshold: Double?) -> Int32 {
        guard let (loaded, _) = load(quiet: false) else { return 1 }
        let outcome = TreeCutter.run(
            text, parser: loaded.parser, filter: loaded.cutFilter,
            threshold: threshold ?? loaded.cutFilter.threshold
        )
        if let declined = outcome.declined { print("✗ declined: \(declined)") }
        print("view: \(outcome.view)")
        let words = TreeCutter.Spans(outcome.view).strings
        for candidate in outcome.candidates {
            let said = candidate.words.map { words[$0] }.joined(separator: " ")
            print("  \(String(format: "%.3f", candidate.pReal)) \(candidate.kept ? "kept   " : "dropped")  \(said)")
        }
        print("out:  \(outcome.text)")
        return 0
    }

    static func batch(path: String, threshold: Double?) -> Int32 {
        struct Item: Decodable {
            let id: String
            let text: String
        }
        let items: [Item]
        do {
            items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("✗ \(path): \(error.localizedDescription)")
            return 1
        }
        guard let (loaded, loadSeconds) = load(quiet: true) else { return 1 }
        let cutoff = threshold ?? loaded.cutFilter.threshold
        var times: [Double] = []
        for item in items {
            autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                let outcome = TreeCutter.run(
                    item.text, parser: loaded.parser, filter: loaded.cutFilter, threshold: cutoff)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                times.append(ms)
                var line: [String: Any] = [
                    "id": item.id, "view": outcome.view, "cut": outcome.cut, "output": outcome.text, "ms": ms,
                    "candidates": outcome.candidates.map {
                        [
                            "words": $0.words, "a": $0.a, "b": $0.b, "p_real": $0.pReal, "kept": $0.kept,
                            "text_features": $0.textFeatures,
                        ] as [String: Any]
                    },
                ]
                if let declined = outcome.declined { line["declined"] = declined }
                emit(line)
            }
        }
        let warm = times.dropFirst().sorted()
        emit(["summary": [
            "items": items.count, "load_s": loadSeconds, "first_ms": times.first ?? 0,
            "median_ms": warm.isEmpty ? 0 : warm[warm.count / 2], "max_ms": warm.last ?? 0,
        ] as [String: Any]])
        return 0
    }

    private static func load(quiet: Bool) -> (SyrinxModel.Loaded, Double)? {
        var result: (SyrinxModel.Loaded, Double)?
        let done = DispatchSemaphore(value: 0)
        Task {
            let started = Date()
            do {
                let loaded = try await SyrinxModel.shared.prepare { label in
                    FileHandle.standardError.write(Data("  \(label)\n".utf8))
                }
                let seconds = Date().timeIntervalSince(started)
                if !quiet { print(String(format: "parser ready in %.2f s", seconds)) }
                result = (loaded, seconds)
            } catch {
                print("✗ parser unavailable: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        return result
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8) else { return }
        print(line)
    }
}
