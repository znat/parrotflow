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

    static func run(term: String, sentence: String?, span: String?) -> Int32 {
        let outcome = Blocking.run { () async -> Result<(TermPortrait.Summary?, Double?), Error> in
            do {
                let summary = try await TermPortrait.shared.summary(for: term)
                guard summary != nil, let sentence, let span else {
                    return .success((summary, nil))
                }
                let score = try await TermPortrait.shared.score(
                    of: span, in: sentence, for: term
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
            if let score {
                let verdict = score > summary.floor ? "authorises" : "no opinion"
                print("score \(String(format: "%.3f", score))   \(verdict)")
            }
            return 0
        }
    }
}
