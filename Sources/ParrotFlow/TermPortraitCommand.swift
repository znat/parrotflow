import Foundation

/// `--portrait <term> ["<sentence>" <span>]` — what a term's confirmed uses say.
///
///     ParrotFlow --portrait Praisy
///     uses 3   tightness 0.874   floor 0.821
///
///     ParrotFlow --portrait Praisy "Let us praise the team." praise
///     uses 3   tightness 0.874   floor 0.821
///     score 0.795   no opinion
///
/// The floor is read off the term's own sentences and never chosen, so printing
/// it is the only way to see what a term has decided about itself.
@available(macOS 14, *)
enum TermPortraitCommand {

    /// Every term that has uses, with what each has decided about itself.
    static func all() -> Int32 {
        let stored = TermUses.load()
        guard !stored.isEmpty else {
            print("no confirmed uses yet — correct a name, or seed one with --learn --in")
            return 0
        }
        print("  term            uses  seeded  floor   last sentence")
        for term in stored.keys.sorted() {
            guard let uses = stored[term] else { continue }
            let seeded = uses.filter { $0.from == .seeded }.count
            let floor = Blocking.run { () async -> Double? in
                (try? await TermPortrait.shared.summary(for: term))??.floor
            }
            let shown = floor.map { String(format: "%.3f", $0) } ?? "   —"
            let last = uses.last?.said ?? ""
            print("  \(pad(term, 15)) \(pad(String(uses.count), 5)) \(pad(String(seeded), 7))"
                + " \(shown)   \(last.prefix(44))")
        }
        return 0
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func run(term: String, sentence: String?, span: String?) -> Int32 {
        let outcome = Blocking.run { () async -> Result<(TermPortrait.Summary?, Double?), Error> in
            do {
                let summary = try await TermPortrait.shared.summary(for: term)
                guard summary != nil, let sentence, let span else {
                    return .success((summary, nil))
                }
                // Windowed the way the gate windows, so this scores the
                // shipped path and not a wider version of it.
                let near = (sentence.range(of: span)).map {
                    TermPortrait.window(around: $0, in: sentence)
                } ?? sentence
                let score = try await TermPortrait.shared.score(
                    of: span, in: near, for: term
                )
                return .success((summary, score))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .failure(let error):
            print("✗ \(error.localizedDescription)")
            return 1
        case .success(let (summary, score)):
            guard let summary else {
                let held = TermUses.load()[term]?.count ?? 0
                print("no portrait: \(held) confirmed use(s), \(TermPortrait.minimum) needed")
                return 0
            }
            print(
                "uses \(summary.uses)   tightness \(String(format: "%.3f", summary.tightness))"
                    + "   floor \(String(format: "%.3f", summary.floor))"
            )
            if sentence == nil {
                for use in TermUses.load()[term] ?? [] {
                    print("  \(use.from == .seeded ? "seeded " : "learned") \(use.said)")
                }
            }
            if let score {
                let verdict: String
                if score > summary.floor {
                    verdict = "authorises"
                } else if score < summary.floor - TermPortrait.refusal {
                    verdict = "refuses"
                } else {
                    verdict = "no opinion"
                }
                print("score \(String(format: "%.3f", score))   \(verdict)")
            }
            return 0
        }
    }
}
