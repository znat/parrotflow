import Foundation

/// `--clause-decide "<text>" --heard "<words>" --term <term>` reads one place
/// with the term's stored sentences and prints every feature, the score and
/// the decision.
///
/// `--clause-decide --batch <items.json>` reads `[{"id", "text", "a", "b",
/// "heard", "term", "uses": [{"said", "span", "counter", "heard"}]}]`, offsets
/// in `Unicode.Scalar`s, and prints one JSON line per item, then a summary line.
enum ClauseDecideCommand {

    static func run(text: String, heard: String, term: String) -> Int32 {
        guard let (parser, model) = load() else { return 1 }
        guard let found = TermUses.occurrence(of: heard, in: text) else {
            print("✗ \"\(heard)\" does not stand in the text as a word")
            return 1
        }
        let a = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: found.lowerBound)
        let rows = TermUses.load()[term] ?? []
        let reading = decide(
            text, at: a ..< a + heard.unicodeScalars.count, heard: heard, term: term, rows: rows,
            parser: parser, model: model)
        guard let reading else {
            print("✗ no parser token at the place")
            return 1
        }
        print(ClauseSession.describe(
            reading.reading, heard: heard, term: term, clause: reading.reading.clause,
            accepted: reading.accepted, refused: reading.refused))
        return 0
    }

    static func batch(path: String) -> Int32 {
        struct Item: Decodable {
            let id: String
            let text: String
            let a: Int
            let b: Int
            let heard: String
            let term: String
            let uses: [Row]
        }
        struct Row: Decodable {
            let said: String
            let span: String
            let counter: Bool
            let heard: String?
        }
        let items: [Item]
        do {
            items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("✗ \(path): \(error.localizedDescription)")
            return 1
        }
        guard let (parser, model) = load() else { return 1 }
        var times: [Double] = []
        for item in items {
            autoreleasepool {
                let rows = item.uses.map {
                    TermUses.Use(said: $0.said, span: $0.span, counter: $0.counter, heard: $0.heard)
                }
                let started = DispatchTime.now().uptimeNanoseconds
                let read = decide(
                    item.text, at: item.a ..< item.b, heard: item.heard, term: item.term, rows: rows,
                    parser: parser, model: model)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                times.append(ms)
                guard let r = read?.reading else {
                    emit(["id": item.id, "declined": "no parser token at the place", "ms": ms])
                    return
                }
                let f = r.features
                var features: [String: Any] = [
                    "pair_acc": f.pairAccepted, "pair_ref": f.pairRefused,
                ]
                for (name, value) in zip(ClauseDecider.Model.names, f.fitted) { features[name] = value ?? NSNull() }
                emit([
                    "id": item.id, "decision": r.decision.rawValue, "p": r.p, "z": r.z, "ms": ms,
                    "clause": r.clause.map { [$0.lowerBound, $0.upperBound] } ?? NSNull(), "features": features,
                ])
            }
        }
        let warm = times.dropFirst().sorted()
        emit(["summary": [
            "items": items.count, "first_ms": times.first ?? 0,
            "median_ms": warm.isEmpty ? 0 : warm[warm.count / 2], "max_ms": warm.last ?? 0,
        ] as [String: Any]])
        return 0
    }

    /// Every row parsed here, uncached: the store is the app's, not the bench's.
    private static func decide(
        _ text: String, at range: Range<Int>, heard: String, term: String, rows: [TermUses.Use],
        parser: Parser, model: ClauseDecider.Model
    ) -> (reading: ClauseDecider.Reading, accepted: Int, refused: Int)? {
        var accepted: [[Float]] = [], refused: [[Float]] = []
        for row in rows {
            guard let v = ClauseDecider.rowVector(row, parser: parser, model: model) else { continue }
            if row.counter { refused.append(v) } else { accepted.append(v) }
        }
        let parsed = ClauseDecider.Parsed(text, parser: parser)
        guard let reading = ClauseDecider.read(
            parsed, at: range, heard: heard, term: term, accepted: accepted, refused: refused,
            acceptedForms: Set(rows.filter { !$0.counter }.compactMap(\.heard).map(ClauseDecider.norm)),
            refusedForms: Set(rows.filter(\.counter).map(\.span).map(ClauseDecider.norm)),
            model: model)
        else { return nil }
        return (reading, accepted.count, refused.count)
    }

    private static func load() -> (Parser, ClauseDecider.Model)? {
        let model: ClauseDecider.Model
        switch ClauseDecider.Model.shared {
        case .success(let loaded): model = loaded
        case .failure(let error):
            print("✗ the clause decider's weights: \(error.localizedDescription)")
            return nil
        }
        var parser: Parser?
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                parser = try await SyrinxModel.shared.prepare { label in
                    FileHandle.standardError.write(Data("  \(label)\n".utf8))
                }.parser
            } catch {
                print("✗ parser unavailable: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        return parser.map { ($0, model) }
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8) else { return }
        print(line)
    }
}
