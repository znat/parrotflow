import Foundation

/// `--clause-decide "<text>" --heard "<words>" --term <term>` reads one place
/// with the term's stored sentences and prints every feature, the score and
/// the decision.
///
/// `--clause-decide --batch <items.json>` reads `[{"id", "text", "a", "b",
/// "heard", "term", "uses": [{"said", "span", "counter", "heard"}]}]`, offsets
/// in `Unicode.Scalar`s, and prints one JSON line per item, then a summary line.
/// An item may carry `memory` (rows per member) for a shared place, and `trim`
/// (with an optional sound `floor`) to drop closed-class edge words first.
enum ClauseDecideCommand {

    static func run(text: String, heard: String, term: String) -> Int32 {
        guard let (parser, model, _) = load() else { return 1 }
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
            /// A shared place: every member's rows, keyed by member.
            let memory: [String: [Row]]?
            /// Trim closed-class edge words first; with `floor`, drop the place
            /// when the trimmed words sound further than that from the term.
            let trim: Bool?
            let floor: Double?
            /// Also print the slot reading at the masked place: UPOS and the
            /// slot head's P.
            let masked: Bool?
        }
        struct Row: Decodable {
            let said: String
            let span: String
            let counter: Bool
            let heard: String?
            let from: String?

            var use: TermUses.Use {
                TermUses.Use(said: said, span: span, from: from.flatMap(TermUses.Use.Source.init(rawValue:)) ?? .correction,
                             counter: counter, heard: heard)
            }
        }
        let items: [Item]
        do {
            items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("✗ \(path): \(error.localizedDescription)")
            return 1
        }
        guard let (parser, model, head) = load() else { return 1 }
        func line(_ r: ClauseDecider.Reading) -> [String: Any] {
            var features: [String: Any] = ["pair_acc": r.features.pairAccepted, "pair_ref": r.features.pairRefused]
            for (name, value) in zip(ClauseDecider.Model.names, r.features.fitted) { features[name] = value ?? NSNull() }
            return ["decision": r.decision.rawValue, "p": r.p, "z": r.z,
                    "clause": r.clause.map { [$0.lowerBound, $0.upperBound] } ?? NSNull(), "features": features]
        }
        var times: [Double] = []
        for item in items {
            autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                var out: [String: Any] = ["id": item.id]
                var range = item.a ..< item.b
                var heard = item.heard
                if item.trim == true {
                    let parsed = ClauseDecider.Parsed(item.text, parser: parser)
                    let scalars = Array(item.text.unicodeScalars)
                    guard let kept = ClauseDecider.trimmed(parsed, text: scalars, at: range, term: item.term) else {
                        emit(["id": item.id, "declined": "nothing left"])
                        return
                    }
                    range = kept
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[kept])
                    heard = String(view)
                    out["place"] = [kept.lowerBound, kept.upperBound]
                    if let floor = item.floor, ClauseDecider.sound(heard: heard, term: item.term) < floor {
                        emit(["id": item.id, "declined": "under the floor", "place": [kept.lowerBound, kept.upperBound]])
                        return
                    }
                }
                if let group = item.memory {
                    var members: [(term: String, reading: ClauseDecider.Reading)] = []
                    var each: [String: Any] = [:]
                    for (term, rows) in group.sorted(by: { $0.key < $1.key }) {
                        let peers = group.filter { $0.key != term }.flatMap { $0.value.map(\.use) }
                        guard let r = decide(item.text, at: range, heard: heard, term: term, rows: rows.map(\.use),
                                             parser: parser, model: model, shared: true, peers: peers)?.reading
                        else { continue }
                        members.append((term, r))
                        each[term] = line(r)
                    }
                    out["members"] = each
                    switch ClauseDecider.decideGroup(members, heard: heard, model: model) {
                    case .write(let term): out["group"] = ["decision": "write", "terms": [term]]
                    case .offer(let top): out["group"] = ["decision": "offer", "terms": top]
                    case .leave: out["group"] = ["decision": "leave", "terms": [String]()]
                    }
                } else if let r = decide(item.text, at: range, heard: heard, term: item.term,
                                         rows: item.uses.map(\.use), parser: parser, model: model)?.reading {
                    out.merge(line(r)) { _, new in new }
                } else {
                    out["declined"] = "no parser token at the place"
                }
                if item.masked == true {
                    let parsed = ClauseDecider.Parsed(item.text, parser: parser)
                    var slot: [String: Any] = [:]
                    if let read = ClauseDecider.slot(parsed, at: range, parser: parser, head: head) {
                        slot["mask"] = read.upos.map(Double.init)
                        slot["tag"] = UPOS.allCases[Parser.argmax(read.upos)].rawValue
                        slot["nominal"] = read.nominal
                        slot["route"] = read.nominal < head.threshold ? "decline" : "open"
                    }
                    out["slot"] = slot
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                times.append(ms)
                out["ms"] = ms
                emit(out)
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
        parser: Parser, model: ClauseDecider.Model, shared: Bool = false, peers: [TermUses.Use] = []
    ) -> (reading: ClauseDecider.Reading, accepted: Int, refused: Int)? {
        var accepted: [[Float]] = [], refused: [[Float]] = []
        for row in rows {
            guard let v = ClauseDecider.rowVector(row, parser: parser, model: model) else { continue }
            if row.counter { refused.append(v) } else { accepted.append(v) }
        }
        let parsed = ClauseDecider.Parsed(text, parser: parser)
        guard let reading = ClauseDecider.read(
            parsed, at: range, heard: heard, term: term, accepted: accepted, refused: refused,
            pairs: ClauseDecider.pairs(heard: heard, term: term, rows: rows, shared: shared, peers: peers), model: model,
            shared: shared)
        else { return nil }
        return (reading, accepted.count, refused.count)
    }

    private static func load() -> (Parser, ClauseDecider.Model, ClauseDecider.SlotHead)? {
        let model: ClauseDecider.Model
        switch ClauseDecider.Model.shared {
        case .success(let loaded): model = loaded
        case .failure(let error):
            print("✗ the clause decider's weights: \(error.localizedDescription)")
            return nil
        }
        let head: ClauseDecider.SlotHead
        switch ClauseDecider.SlotHead.shared {
        case .success(let loaded): head = loaded
        case .failure(let error):
            print("✗ the slot head's weights: \(error.localizedDescription)")
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
        return parser.map { ($0, model, head) }
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8) else { return }
        print(line)
    }
}
