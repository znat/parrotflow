import Foundation

/// `--sentence-case` — how `SentenceJoin.written` writes the word after each
/// sentence mark, once the mark is gone. No model.
///
///     ParrotFlow --sentence-case "I will ask him. Nathan knows."
///       next       Nathan -> Nathan
///
/// A mark the abbreviation list refuses prints nothing.
/// `scripts/check-sentence-case.sh` is the run.
@available(macOS 14, *)
enum SentenceCaseCommand {

    static func run(_ text: String) -> Int32 {
        let config = (try? ConfigStore.load()) ?? Config()
        let terms = Array(config.vocabulary.terms.keys)
        let found = SentenceJoin.boundaries(
            in: text, scanning: SentenceJoin.scanned(config.transcription.marks(for: "en")),
            refusing: config.abbreviations
        )
        for boundary in found {
            var joined = text
            joined.remove(at: boundary.at)
            let offset = text.distance(from: text.startIndex, to: boundary.next.lowerBound) - 1
            let word = String(text[boundary.next])
            print("  next       \(word) -> \(SentenceJoin.written(word, in: joined, at: offset, terms: terms))")
        }
        return 0
    }
}
