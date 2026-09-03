import FluidAudio
import Foundation
import Yams

/// `--invented-tail` — the endings Parakeet writes over silence, scored against
/// real decodes.
///
/// Every case is a word array taken from `trace.jsonl`, so what is scored is
/// what the decoder actually returned on a clip somebody dictated. The words
/// are turned back into token timings and handed to the real
/// `Transcriber.withoutInventedTail`, which means the text trim is scored too
/// — the half that can go wrong quietly, because `ASRResult.text` and the
/// timings are two different objects and only one of them reaches the screen.
///
/// The set is meant to be read in both directions. A rule that drops an
/// invention nobody said is worth nothing if it also drops "Kim?" off the end
/// of a question, so the cases that must survive outnumber the ones that must
/// go.
enum InventedTailCommand {

    private struct Case {
        let name: String
        let speechEnd: Double?
        let text: String
        let words: [Trace.Word]
        /// The text that must survive. Equal to `text` when nothing goes.
        let keeps: String
        /// `burst`, `after speech`, or nil when nothing may be dropped.
        let reason: String?
        /// What `decodedNothing` must say, when the case asks.
        let nothing: Bool?
    }

    static func run(casesPath: String?) -> Int32 {
        let path = casesPath ?? FileManager.default.currentDirectoryPath
            + "/tests/invented-tail-cases.yaml"
        let cases: [Case]
        do {
            cases = try loadCases(at: path)
        } catch {
            print("✗ cases: \(error.localizedDescription)")
            return 1
        }

        var failures = 0
        for testCase in cases {
            failures += check(testCase) ? 0 : 1
        }
        print("")
        print("  \(cases.count - failures)/\(cases.count)")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ testCase: Case) -> Bool {
        let result = decode(testCase)
        let trimmed = Transcriber.withoutInventedTail(result, speechEnd: testCase.speechEnd)
        let found = Transcriber.inventedTail(words: testCase.words, speechEnd: testCase.speechEnd)

        var problems: [String] = []
        if trimmed.text != testCase.keeps {
            problems.append("kept \"\(trimmed.text)\", expected \"\(testCase.keeps)\"")
        }
        if found?.reason != testCase.reason {
            problems.append("read it as \(found?.reason ?? "speech"), "
                + "expected \(testCase.reason ?? "speech")")
        }
        // The timings have to lose exactly the words the text lost, or the HUD
        // and the trace describe different sentences.
        let lostTimings = testCase.words.count - Trace.words(from: trimmed.tokenTimings ?? []).count
        let lostText = words(in: testCase.text) - words(in: trimmed.text)
        if lostTimings != lostText {
            problems.append("\(lostTimings) word(s) of timing dropped against \(lostText) of text")
        }
        if let wanted = testCase.nothing {
            let gate = Transcriber.SpeechGate(
                samples: [], segments: [(start: 0, end: testCase.speechEnd ?? 1)], decodable: true
            )
            let got = Transcriber.decodedNothing(result, gate: gate)
            if got != wanted {
                problems.append("decodedNothing said \(got), expected \(wanted)")
            }
        }

        guard problems.isEmpty else {
            print("  ✗ \(testCase.name)")
            for problem in problems { print("      \(problem)") }
            return false
        }
        print("  ✓ \(testCase.name) — \(describe(found, kept: trimmed.text, of: testCase))")
        return true
    }

    private static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func describe(
        _ found: (count: Int, reason: String)?, kept: String, of testCase: Case
    ) -> String {
        guard let found else { return "kept whole" }
        guard kept != testCase.text else { return "\(found.reason), and the trim refused" }
        return "dropped \(found.count) (\(found.reason)), left \"\(kept)\""
    }

    /// The case as the decoder would have handed it over: one token per word,
    /// marked the way SentencePiece marks a word's first piece, so
    /// `Trace.words` gives the case's own words back.
    private static func decode(_ testCase: Case) -> ASRResult {
        ASRResult(
            text: testCase.text,
            confidence: testCase.words.map(\.confidence).min() ?? 0,
            duration: testCase.words.last?.end ?? 0,
            processingTime: 0,
            tokenTimings: testCase.words.map {
                TokenTiming(
                    token: "\u{2581}" + $0.word,
                    tokenId: 0,
                    startTime: $0.start,
                    endTime: $0.end,
                    confidence: $0.confidence
                )
            }
        )
    }

    private static func loadCases(at path: String) throws -> [Case] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let raw = try YAMLDecoder().decode([RawCase].self, from: text)
        return try raw.map { one in
            let words = try one.words.map(word)
            let text = one.text ?? words.map(\.word).joined(separator: " ")
            return Case(
                name: one.name,
                speechEnd: one.speechEnd,
                text: text,
                words: words,
                keeps: one.keeps ?? text,
                reason: one.reason,
                nothing: one.nothing
            )
        }
    }

    /// `<word> <start> <end> <confidence>`. Read from the right, so a word
    /// that is itself a number is still a word.
    private static func word(_ line: String) throws -> Trace.Word {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 4, let start = Double(fields[fields.count - 3]),
            let end = Double(fields[fields.count - 2]),
            let confidence = Float(fields[fields.count - 1])
        else {
            throw CaseError.word(line)
        }
        return Trace.Word(
            word: fields[0..<(fields.count - 3)].joined(separator: " "),
            start: start, end: end, confidence: confidence
        )
    }

    private enum CaseError: LocalizedError {
        case word(String)

        var errorDescription: String? {
            switch self {
            case .word(let line):
                return "a word needs \"<word> <start> <end> <confidence>\", got \"\(line)\""
            }
        }
    }

    private struct RawCase: Decodable {
        let name: String
        let speechEnd: Double?
        let text: String?
        let words: [String]
        let keeps: String?
        let reason: String?
        let nothing: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case speechEnd = "speech_end"
            case text, words, keeps, reason, nothing
        }
    }
}
