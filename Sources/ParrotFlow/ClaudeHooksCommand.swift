import Foundation
import Yams

/// The terminal side of `ClaudeVoice`.
///
///   --claude-voice-test <cases> score the text rules, no audio
enum ClaudeHooksCommand {

    // MARK: - Checks

    struct Cases: Decodable {
        struct Clean: Decodable { var name: String; var input: String; var want: String }
        struct Progress: Decodable {
            var name: String; var tool: String; var input: [String: String]?; var want: String?
        }
        struct Turn: Decodable {
            var name: String; var lines: [String]; var answer: String; var recap: String?
            var earlier: String?
        }
        struct Parse: Decodable { var name: String; var raw: String; var say: String; var tone: String?; var opener: String? }
        var clean: [Clean] = []
        var progress: [Progress] = []
        var turns: [Turn] = []
        var parse: [Parse] = []
        var capped: [Clean] = []
        var redacted: [Clean] = []
        struct Grounding: Decodable { var name: String; var said: String; var source: String; var kept: Bool }
        var grounded: [Grounding] = []
        var speakable: [Clean] = []
        var spoken: [Clean] = []
        struct Summary: Decodable { var name: String; var lines: [String]; var want: String? }
        var summary: [Summary] = []

        enum CodingKeys: String, CodingKey {
            case clean, progress, turns, parse, capped, redacted, grounded, speakable, spoken, summary
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clean = try c.decodeIfPresent([Clean].self, forKey: .clean) ?? []
            progress = try c.decodeIfPresent([Progress].self, forKey: .progress) ?? []
            turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
            parse = try c.decodeIfPresent([Parse].self, forKey: .parse) ?? []
            capped = try c.decodeIfPresent([Clean].self, forKey: .capped) ?? []
            redacted = try c.decodeIfPresent([Clean].self, forKey: .redacted) ?? []
            grounded = try c.decodeIfPresent([Grounding].self, forKey: .grounded) ?? []
            speakable = try c.decodeIfPresent([Clean].self, forKey: .speakable) ?? []
            spoken = try c.decodeIfPresent([Clean].self, forKey: .spoken) ?? []
            summary = try c.decodeIfPresent([Summary].self, forKey: .summary) ?? []
        }
    }

    static func test(cases path: String) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("✗ cannot read \(path)")
            return 2
        }
        let cases: Cases
        do { cases = try YAMLDecoder().decode(Cases.self, from: text) } catch {
            print("✗ \(path): \(error)")
            return 2
        }
        var passed = 0
        var total = 0
        func check(_ name: String, got: String?, want: String?) {
            total += 1
            if got == want {
                passed += 1
                print("  ✓ \(name)")
            } else {
                print("  ✗ \(name)\n      got   \(got ?? "(silent)")\n      want  \(want ?? "(silent)")")
            }
        }
        for item in cases.clean {
            check(item.name, got: ClaudeSpeakable.clean(item.input), want: item.want)
        }
        for item in cases.progress {
            let line = ClaudeSpeakable.progress(tool: item.tool, input: item.input ?? [:])
            check(item.name, got: line?.text, want: item.want)
        }
        for item in cases.turns {
            let ended = ClaudeSpeakable.lastTurn(lines: item.lines)
            check(item.name, got: ended?.answer, want: item.answer)
            check(item.name + " (recap)", got: ended?.recap, want: item.recap)
            if let earlier = item.earlier {
                check(item.name + " (earlier)", got: ended?.earlier?.answer, want: earlier)
            }
        }
        for item in cases.parse {
            let parsed = ClaudeSpeakable.parseSpoken(item.raw)
            check(item.name, got: parsed.say, want: item.say)
            check(item.name + " (tone)", got: parsed.tone, want: item.tone)
            check(item.name + " (opener)", got: parsed.opener, want: item.opener)
        }
        for item in cases.capped {
            check(item.name, got: ClaudeSpeakable.capped(item.input), want: item.want)
        }
        for item in cases.redacted {
            check(item.name, got: ClaudeSpeakable.redacted(item.input), want: item.want)
        }
        for item in cases.summary {
            check(item.name, got: ClaudeSpeakable.latestSummary(lines: item.lines), want: item.want)
        }
        for item in cases.spoken {
            check(item.name, got: ClaudeSpeakable.clean(item.input), want: item.want)
        }
        for item in cases.speakable {
            check(item.name, got: ClaudeSpeakable.speakable(item.input), want: item.want)
        }
        for item in cases.grounded {
            let keeps = ClaudeSpeakable.grounded(item.said, in: item.source) >= ClaudeSpeakable.groundedFloor
            check(item.name, got: keeps ? "kept" : "plain", want: item.kept ? "kept" : "plain")
        }
        let language = ClaudeSpeakable.language(of:)
        check("a French request is French", got: language("Est-ce que tu peux relancer les tests sur cette branche ?"),
              want: "fr")
        check("an English request is English", got: language("Can you rerun the tests on that branch?"), want: "en")
        check("a short line has no language", got: language("ok go") ?? "none", want: "none")
        check("a path is not a language", got: language("codex report came back /Users/me/training/BOUNDARY_DATA_V2.md")
              ?? "none", want: "en")
        guard let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 6))
        else { return 2 }
        check("an English date", got: ClaudeSpeakable.spokenDates("on 2026-11-06", now: now), want: "on November 6")
        check("an English date, another year", got: ClaudeSpeakable.spokenDates("2025-03-01", now: now),
              want: "March 1, 2025")
        check("a French date", got: ClaudeSpeakable.spokenDates("le 2026-11-06", now: now, language: "fr"),
              want: "le 6 novembre")
        check("a French date, another year", got: ClaudeSpeakable.spokenDates("2025-03-01", now: now, language: "fr"),
              want: "1 mars 2025")
        check("French units", got: ClaudeSpeakable.clean("en 12 s, 40 %", language: "fr"),
              want: "en 12 secondes, 40 pour cent.")
        check("a capital after a period", got: ClaudeSpeakable.capped("A new term. my examples were wrong."),
              want: "A new term. My examples were wrong.")
        print("\n\(passed)/\(total)")
        return passed == total ? 0 : 1
    }
}
