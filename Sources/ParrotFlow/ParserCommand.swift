import Darwin
import Foundation

/// `--parse "<text>"` prints one line per word: index, word, head, label,
/// part of speech and UTF-16 range.
///
/// `--parse --batch <file.json>` reads `[{"id", "words"} | {"id", "text"}]`,
/// each with an optional `"language"`, and prints one JSON line per item with
/// its time and the process's memory after it, then a summary line. `--split`
/// skips the model and prints the words only.
enum ParserCommand {

    static func run(text: String, language: String) -> Int32 {
        guard language == "en" else {
            print("✗ abstained: no word splitter for \(language)")
            return 1
        }
        guard let words = WordSplit.english(text) else {
            print("✗ abstained: the English splitter cannot map this text")
            return 1
        }
        guard let (parser, _) = load() else { return 1 }
        guard let parse = parser.parse(words: words, language: language) else {
            print("✗ abstained: \(reason(parser, words))")
            return 1
        }
        for (index, (word, tree)) in zip(words.all, parse.words).enumerated() {
            let range = "\(word.utf16.lowerBound)-\(word.utf16.upperBound)"
            print([String(index + 1), word.string, String(tree.head), tree.label, tree.tag.rawValue, range]
                .joined(separator: "\t"))
        }
        return 0
    }

    static func batch(path: String, splitOnly: Bool) -> Int32 {
        struct Item: Decodable {
            let id: String
            let words: [String]?
            let text: String?
            let language: String?
        }
        let items: [Item]
        do {
            items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("✗ \(path): \(error.localizedDescription)")
            return 1
        }
        var parser: Parser?
        var loadSeconds = 0.0
        if !splitOnly {
            guard let (loaded, seconds) = load(quiet: true) else { return 1 }
            parser = loaded
            loadSeconds = seconds
        }
        var times: [Double] = []
        for item in items {
            autoreleasepool {
                let language = item.language ?? "en"
                var line: [String: Any] = ["id": item.id]
                defer { emit(line) }
                let words: Words
                if let strings = item.words {
                    words = Words(joining: strings)
                } else if let text = item.text, language == "en", let split = WordSplit.english(text) {
                    words = split
                } else {
                    line["abstain"] = "no word split"
                    return
                }
                line["words"] = words.all.map(\.string)
                line["utf16"] = words.all.map { [$0.utf16.lowerBound, $0.utf16.upperBound] }
                guard let parser else { return }
                line["ids"] = parser.subwords(words).ids
                let started = DispatchTime.now().uptimeNanoseconds
                let parse = parser.parse(words: words, language: language)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                guard let parse else {
                    line["abstain"] = reason(parser, words)
                    return
                }
                times.append(ms)
                line["ms"] = ms
                line["heads"] = parse.words.map(\.head)
                line["labels"] = parse.words.map(\.label)
                line["upos"] = parse.words.map(\.tag.rawValue)
                line.merge(memory()) { $1 }
            }
        }
        let first = times.first ?? 0
        let warm = times.dropFirst().sorted()
        emit(["summary": [
            "items": items.count, "parsed": times.count, "load_s": loadSeconds, "first_ms": first,
            "median_ms": warm.isEmpty ? 0 : warm[warm.count / 2], "max_ms": warm.last ?? 0,
            "units": SyrinxModel.computeUnits == .all ? "all" : "cpuAndGPU",
        ].merging(memory()) { $1 }])
        return 0
    }

    private static func load(quiet: Bool = false) -> (Parser, Double)? {
        var result: (Parser, Double)?
        let done = DispatchSemaphore(value: 0)
        Task {
            let started = Date()
            do {
                let parser = try await SyrinxModel.shared.prepare { label in
                    FileHandle.standardError.write(Data("  \(label)\n".utf8))
                }.parser
                let seconds = Date().timeIntervalSince(started)
                if !quiet {
                    print(String(format: "parser ready in %.2f s", seconds))
                }
                result = (parser, seconds)
            } catch {
                print("✗ parser unavailable: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        return result
    }

    private static func reason(_ parser: Parser, _ words: Words) -> String {
        let count = parser.subwords(words).ids.count
        return count > Parser.length ? "\(count) subwords, over the \(Parser.length) limit" : "the parser declined"
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8) else { return }
        print(line)
    }

    private static func memory() -> [String: Double] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = 1024.0 * 1024.0
        return ["phys_footprint_mb": Double(info.phys_footprint) / mb, "resident_mb": Double(info.resident_size) / mb]
    }
}
