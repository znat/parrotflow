import Darwin
import Foundation

/// `--parse "<text>" [--lang xx]` prints one line per word: index, word, head,
/// label, part of speech, features, NER type, character offset-length and the
/// four tag probabilities.
///
/// `--parse --batch <file.json> [--with-mask]` reads `[{"id", "language",
/// "text" | "words"}]` and prints one JSON line per item, then a summary.
/// `--parse --encode "<text>"` prints the tokenizer's ids for the whole string.
@available(macOS 14, *)
enum ParserCommand {

    static func run(text: String, language: String) -> Int32 {
        guard let (parser, _) = load(quiet: false) else { return 1 }
        let field: ParseField
        do {
            field = try ParseField.of(text, language: language, parser: parser)
        } catch {
            print("✗ abstained: \(error.localizedDescription)")
            return 1
        }
        for (index, word) in field.words.enumerated() {
            let feats = word.feats.isEmpty ? "_" : word.feats.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "|")
            let tags = zip(field.tagNames, word.tags).map { String(format: "%@=%.4f", $0.0, $0.1) }
                .joined(separator: " ")
            print([String(index + 1), word.text, String(word.head), word.deprel, word.upos, feats,
                   word.ner ?? "_", "\(word.at)-\(word.len)", tags].joined(separator: "\t"))
        }
        return 0
    }

    static func encode(_ text: String) -> Int32 {
        do {
            let tokenizer = try ScalarBPE(
                contentsOf: SlotModel.tokenizerDirectory.appendingPathComponent("tokenizer.json"))
            print("ids \(tokenizer.encode(text).map(String.init).joined(separator: ","))")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    static func batch(path: String, withMask: Bool) -> Int32 {
        struct Item: Decodable {
            let id: String
            let language: String?
            let text: String?
            let words: [String]?
        }
        let items: [Item]
        do {
            items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("✗ \(path): \(error.localizedDescription)")
            return 1
        }
        var footprint: [String: Double] = [:]
        if withMask {
            let loaded = Blocking.run { () async -> String? in
                // One prediction, so the mask's weights are resident before the footprint is read.
                do {
                    _ = try await SlotProbe.load().at(left: "we can try", right: " tomorrow")
                    return nil
                } catch { return error.localizedDescription }
            }
            if let loaded {
                print("✗ slot model unavailable: \(loaded)")
                return 1
            }
            footprint["after_mask"] = memory().footprint
        }
        guard let (parser, loadSeconds) = load(quiet: true) else { return 1 }
        footprint["after_parser"] = memory().footprint

        var times: [Double] = []
        for item in items {
            autoreleasepool {
                var line: [String: Any] = ["id": item.id]
                defer { emit(line) }
                let language = item.language ?? "en"
                let started = DispatchTime.now().uptimeNanoseconds
                let field: ParseField
                do {
                    if let words = item.words {
                        field = try ParseField.of(words: words, language: language, parser: parser)
                    } else {
                        field = try ParseField.of(item.text ?? "", language: language, parser: parser)
                    }
                } catch let abstained as ParseField.Abstained {
                    line["abstain"] = abstained.code.rawValue
                    return
                } catch {
                    line["abstain"] = error.localizedDescription
                    return
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                times.append(ms)
                line["language"] = language
                line["tag_names"] = field.tagNames
                line["ms"] = ms
                line["parse_ms"] = field.windows.reduce(0) { $0 + $1.parseSeconds } * 1000
                line["ner_ms"] = field.windows.reduce(0) { $0 + $1.nerSeconds } * 1000
                line["windows"] = field.windows.map { ["ids": $0.ids, "ner_ids": $0.nerIDs] }
                line["words"] = field.words.map { word -> [String: Any] in
                    [
                        "at": word.at, "len": word.len, "text": word.text, "upos": word.upos,
                        "feats": word.feats, "head": word.head, "deprel": word.deprel,
                        "ner": word.ner ?? NSNull(), "tags": word.tags.map(Double.init),
                    ]
                }
            }
        }
        let end = memory()
        footprint["end"] = end.footprint
        let warm = times.dropFirst().sorted()
        emit(["summary": [
            "items": items.count, "parsed": times.count, "load_s": loadSeconds, "first_ms": times.first ?? 0,
            "median_ms": warm.isEmpty ? 0 : warm[warm.count / 2], "max_ms": warm.last ?? 0,
            "footprint_mb": footprint, "peak_mb": end.peak, "with_mask": withMask,
        ] as [String: Any]])
        return 0
    }

    private static func load(quiet: Bool) -> (Parser, Double)? {
        Blocking.run { () async -> (Parser, Double)? in
            let started = Date()
            do {
                let parser = try await SyrinxParser.shared.prepare { label in
                    FileHandle.standardError.write(Data("  \(label)\n".utf8))
                }
                let seconds = Date().timeIntervalSince(started)
                if !quiet {
                    FileHandle.standardError.write(Data(String(format: "parser ready in %.2f s\n", seconds).utf8))
                }
                return (parser, seconds)
            } catch {
                print("✗ parser unavailable: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8) else { return }
        print(line)
    }

    private static func memory() -> (footprint: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = 1024.0 * 1024.0
        return (Double(info.phys_footprint) / mb, Double(info.ledger_phys_footprint_peak) / mb)
    }
}
