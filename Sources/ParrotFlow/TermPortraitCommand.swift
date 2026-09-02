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
/// A term with enough counter-examples is read against those instead of against
/// the floor, and both scores are printed:
///
///     ParrotFlow --portrait BetterStack "…a better stack for us." "better stack"
///     uses 5   against 4   tightness 0.882   floor 0.858
///     score 0.928   counters 1.018   refuses
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
        print("  term            uses  seeded  against  floor   last sentence")
        for term in stored.keys.sorted() {
            guard let all = stored[term] else { continue }
            // `uses` and `seeded` count what a portrait is built from, so a
            // counter shows in one column only.
            let uses = all.filter { !$0.counter }
            let against = all.count - uses.count
            let seeded = uses.filter { $0.from == .seeded }.count
            let floor = Blocking.run { () async -> Double? in
                (try? await TermPortrait.shared.summary(for: term))??.floor
            }
            let shown = floor.map { String(format: "%.3f", $0) } ?? "   —"
            let last = uses.last?.said ?? ""
            print("  \(pad(term, 15)) \(pad(String(uses.count), 5)) \(pad(String(seeded), 7))"
                + " \(pad(String(against), 8)) \(shown)   \(last.prefix(44))")
        }
        return 0
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func run(term: String, sentence: String?, span: String?) -> Int32 {
        typealias Answer = (TermPortrait.Summary?, TermPortrait.Reading?)
        let outcome = Blocking.run { () async -> Result<Answer, Error> in
            do {
                let summary = try await TermPortrait.shared.summary(for: term)
                guard summary != nil, let sentence, let span else {
                    return .success((summary, nil))
                }
                // Windowed the way the gate windows, so this scores the
                // shipped path and not a wider version of it. The gate is
                // handed a range; here the span has to be found, and it is
                // found as a word for the same reason `TermUses` does.
                let near = TermUses.occurrence(of: span, in: sentence).map {
                    TermPortrait.window(around: $0, in: sentence)
                } ?? sentence
                let reading = try await TermPortrait.shared.read(span, in: near, as: term)
                return .success((summary, reading))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .failure(let error):
            print("✗ \(error.localizedDescription)")
            return 1
        case .success(let (summary, reading)):
            guard let summary else {
                let held = TermUses.load()[term]?.filter { !$0.counter }.count ?? 0
                print("no portrait: \(held) confirmed use(s), \(TermPortrait.minimum) needed")
                return 0
            }
            // `against` only when there is one, so a term with no counters
            // prints the line it has always printed.
            let against = summary.counters > 0 ? "against \(summary.counters)   " : ""
            print(
                "uses \(summary.uses)   \(against)"
                    + "tightness \(String(format: "%.3f", summary.tightness))"
                    + "   floor \(String(format: "%.3f", summary.floor))"
            )
            if sentence == nil {
                for use in TermUses.load()[term] ?? [] {
                    let mark = use.counter
                        ? "against"
                        : (use.from == .seeded ? "seeded " : "learned")
                    print("  \(mark) \(use.said)")
                }
            }
            if let reading {
                let verdict: String
                switch reading.verdict {
                case .authorises: verdict = "authorises"
                case .refuses:    verdict = "refuses"
                case .nothing:    verdict = "no opinion"
                }
                let counters = reading.against
                    .map { "counters \(String(format: "%.3f", $0))   " } ?? ""
                print("score \(String(format: "%.3f", reading.own))   \(counters)\(verdict)")
            }
            return 0
        }
    }
}
