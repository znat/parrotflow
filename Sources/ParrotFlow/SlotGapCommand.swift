import Foundation

/// `--slot-gap "<sentence>" <heard> <term>` — what the slot says about a rewrite.
///
///     ParrotFlow --slot-gap "The old house looked ghostly in the fog." ghostly Ghostty
///     expected  grey like deserted good lost beautiful white cool green ugly
///     gap       -0.243   refuse
///
/// The ten words are the reference the two readings are measured against, and
/// they are printed because they explain the number: a slot whose ten words are
/// pronouns cannot tell two names apart, and the gap comes out near zero.
///
/// `--lang fr` reads the verdict at the French floor. The gap itself is the
/// same number in every language; only the line it is compared against moves.
///
/// This is what `scripts/check-slot-gap.sh` scores, so a case set runs against
/// the shipped path rather than a copy of it.
@available(macOS 14, *)
enum SlotGapCommand {

    static func run(sentence: String, heard: String, term: String, language: String) -> Int32 {
        let outcome = Blocking.run { () async -> Result<(Double, [String]), Error> in
            do {
                guard let found = sentence.range(of: heard) else {
                    return .failure(SlotReference.Failure.noSlot(heard))
                }
                let left = String(sentence[sentence.startIndex ..< found.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let right = String(sentence[found.upperBound...])
                let words = try await SlotReference.expected(left: left, right: right)
                let gap = try await SlotReference.gap(
                    term: term, heard: heard, left: left, right: right
                )
                return .success((gap, words))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .failure(let error):
            print("✗ \(error.localizedDescription)")
            return 1
        case .success(let (gap, words)):
            print("expected  \(words.joined(separator: " "))")
            let floor = ((try? ConfigStore.load()) ?? Config())
                .transcription.slotFloor(for: language)
            let verdict = gap < -floor ? "refuse" : "no opinion"
            print("gap       \(String(format: "%+.3f", gap))   \(verdict)")
            return 0
        }
    }
}
