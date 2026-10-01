import Foundation
import MLX

/// `--context-spelling-test <cases.json> [--reference <reference.json>]` — the
/// context spelling pass over a case file, one JSON row per case.
///
/// A case holds `text`, `context`, and optionally `code`, `place`, `people`
/// and `roster` joined on `; `, `input: {text}` and `language`. With a
/// reference in the same shape, it prints per case whether the candidate set,
/// the gains and the output agree.
///
/// Each case is scored twice with the model loaded. `score_ms` is the second
/// call, `first_ms` the first.
enum ContextSpellingCommand {

    struct Case: Decodable {
        struct Input: Decodable {
            var before: String?
            var text: String?
        }

        var text: String
        var context: String
        var code: String?
        var place: String?
        var people: String?
        var roster: String?
        var input: Input?
        var language: String?
    }

    struct Chosen: Codable {
        let span: String
        let term: String
        let start: Int
        let end: Int
        let delta: Double?
    }

    struct Row: Codable {
        let `case`: Int
        let text: String
        let candidates: [ContextSpelling.Candidate]
        let chosen: [Chosen]
        let output: String
        var firstMs: Double?
        var scoreMs: Double?

        enum CodingKeys: String, CodingKey {
            case `case`, text, candidates, chosen, output
            case firstMs = "first_ms"
            case scoreMs = "score_ms"
        }
    }

    static func run(cases path: String, reference: String?) -> Int32 {
        let cases: [Case]
        do {
            cases = try JSONDecoder().decode(
                [Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("✗ \(path): \(error.localizedDescription)")
            return 1
        }
        guard SentenceReadings.isCached else {
            print("✗ the sentence model is not cached at \(SentenceReadings.directory.path)")
            return 1
        }
        let run = Blocking.run { () async -> (rows: [Row], loaded: Int)? in
            do { try await SentenceReadings.shared.prepare() } catch {
                print("✗ the sentence model did not load: \(error.localizedDescription)")
                return nil
            }
            let loaded = Memory.activeMemory
            Memory.peakMemory = 0
            var rows: [Row] = []
            for (index, item) in cases.enumerated() {
                rows.append(await row(index, item))
            }
            return (rows, loaded)
        }
        guard let (rows, loaded) = run else { return 1 }

        guard let reference else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(rows),
                  let json = String(bytes: data, encoding: .utf8) else { return 1 }
            print(json)
            return 0
        }
        let expected: [Row]
        do {
            expected = try JSONDecoder().decode(
                [Row].self, from: Data(contentsOf: URL(fileURLWithPath: reference)))
        } catch {
            print("✗ \(reference): \(error.localizedDescription)")
            return 1
        }
        let code = compare(rows, against: expected)
        print("memory: \(loaded / 1_048_576) MB with the model loaded,"
            + " peak \(Memory.peakMemory / 1_048_576) MB while scoring")
        return code
    }

    private static func row(_ index: Int, _ item: Case) async -> Row {
        func list(_ joined: String?) -> [String] {
            (joined ?? "").components(separatedBy: "; ").filter { !$0.isEmpty }
        }
        var screen = ContextSpelling.Screen(
            text: item.context, code: list(item.code), place: item.place ?? "",
            people: list(item.people), roster: list(item.roster))
        if screen.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            screen.text = [item.input?.before, item.input?.text]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }
        let language = item.language ?? "en"
        let found = ContextSpelling.capped(ContextSpelling.candidates(
            in: item.text, screen: screen, voice: Phonemes.voice(for: language),
            tokens: Tagger.tokens(in: item.text, language: language)))
        var result = Row(case: index, text: item.text, candidates: found, chosen: [],
                         output: item.text)
        guard !found.isEmpty else { return result }

        let prefix = ContextSpelling.prefix(of: ContextSpelling.clean(screen.text))
        let continuations = [item.text] + found.map { ContextSpelling.rewrite(item.text, with: [$0]) }
        var totals: [Double] = []
        var times: [Double] = []
        for _ in 0..<2 {
            let started = CFAbsoluteTimeGetCurrent()
            do {
                totals = try await SentenceReadings.shared.totals(
                    prefix: prefix, continuations: continuations, budget: ContextSpelling.budget)
            } catch {
                FileHandle.standardError.write(Data(
                    "case \(index): not scored — \(error.localizedDescription)\n".utf8))
                return result
            }
            times.append(((CFAbsoluteTimeGetCurrent() - started) * 10000).rounded() / 10)
        }
        let scored = ContextSpelling.scoring(found, totals)
        let chosen = ContextSpelling.choose(scored)
        result = Row(
            case: index, text: item.text, candidates: scored,
            chosen: chosen.map {
                Chosen(span: $0.span, term: $0.term, start: $0.start, end: $0.end, delta: $0.delta)
            },
            output: ContextSpelling.rewrite(item.text, with: chosen),
            firstMs: times.first, scoreMs: times.last)
        return result
    }

    /// Candidate sets by position and term, the largest gain difference over
    /// the candidates both found, and the output.
    ///
    /// Passes on the same cases, the same candidate sets, every candidate
    /// scored, and the same outputs. Gains are reported and not gated: the
    /// prototype's own scorer moved by 0.15 nat at the median, and 4.6 at worst,
    /// between its cached and uncached passes over the same tokens.
    private static func compare(_ rows: [Row], against expected: [Row]) -> Int32 {
        let tolerance = 0.1
        var (sameSets, withinTolerance, sameOutputs, faults) = (0, 0, 0, 0)
        let byCase = Dictionary(expected.map { ($0.case, $0) }, uniquingKeysWith: { first, _ in first })
        for absent in Set(expected.map(\.case)).subtracting(rows.map(\.case)).sorted() {
            print("case \(absent): in the reference, not run")
            faults += 1
        }
        for row in rows {
            guard let want = byCase[row.case] else {
                print("case \(row.case): not in the reference")
                faults += 1
                continue
            }
            if row.candidates.contains(where: { $0.delta == nil }) {
                print("case \(row.case): not scored")
                faults += 1
            }
            func key(_ c: ContextSpelling.Candidate) -> String { "\(c.start):\(c.end):\(c.term)" }
            let mine = Dictionary(row.candidates.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
            let theirs = Dictionary(want.candidates.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
            let sameSet = Set(mine.keys) == Set(theirs.keys)
            let gap = mine.compactMap { key, candidate -> Double? in
                guard let a = candidate.delta, let b = theirs[key]?.delta else { return nil }
                return abs(a - b)
            }.max() ?? 0
            let sameOutput = row.output == want.output
            sameSets += sameSet ? 1 : 0
            withinTolerance += gap <= tolerance ? 1 : 0
            sameOutputs += sameOutput ? 1 : 0
            var line = String(format: "case %2d  %@ set  %@ gap %.3f  %@ output",
                              row.case, sameSet ? "=" : "≠", gap <= tolerance ? "=" : "≠", gap,
                              sameOutput ? "=" : "≠")
            if let ms = row.scoreMs { line += String(format: "  %.0fms", ms) }
            if !sameSet {
                line += "  only here: \(Set(mine.keys).subtracting(theirs.keys).sorted())"
                    + "  only there: \(Set(theirs.keys).subtracting(mine.keys).sorted())"
            }
            print(line)
        }
        let times = rows.compactMap(\.scoreMs).sorted()
        let firsts = rows.compactMap(\.firstMs).sorted()
        print("\(rows.count) cases: \(sameSets) same candidate set, \(withinTolerance) within"
            + " \(tolerance) nat, \(sameOutputs) same output")
        if !times.isEmpty {
            print(String(format: "score ms over %d scored: median %.0f, worst %.0f;"
                + " first call median %.0f, worst %.0f",
                times.count, times[times.count / 2], times[times.count - 1],
                firsts[firsts.count / 2], firsts[firsts.count - 1]))
        }
        return sameSets == rows.count && sameOutputs == rows.count && faults == 0 ? 0 : 1
    }
}
