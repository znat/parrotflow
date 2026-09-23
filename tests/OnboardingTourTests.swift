import Foundation

@main enum OnboardingTourTests {
    static func main() throws {
        let examples = OnboardingTour.examples
        precondition(examples.count == 12)
        for name in ["dates", "money"] {
            precondition(examples.filter { $0.code.contains { $0.text == "- name: \(name)_en" } }.count == 2)
        }
        precondition(examples[0].kind == .vocabulary)
        precondition(examples[0].speed == 1.2)
        precondition(abs(examples[0].revealDuration / examples[0].speed - 0.95 / 1.5 * 1.25) < 0.0001)
        precondition(examples[6].revealDuration == 0.95 * 1.25)
        precondition(OnboardingTour.at(-1).index == 0)
        precondition(OnboardingTour.at(OnboardingTour.total + 100).index == examples.count - 1)
        for paused in [false, true] {
            for ready in [false, true] {
                for failed in [false, true] {
                    for elapsed in [0.0, OnboardingTour.total - 0.001, OnboardingTour.total] {
                        precondition(OnboardingTour.shouldFinishSetupTour(elapsed: elapsed,
                            paused: paused, downloadsReady: ready, blockingFailure: failed)
                            == (failed || (!paused && ready && elapsed >= OnboardingTour.total)))
                    }
                }
            }
        }
        for (index, example) in examples.enumerated() {
            let start = OnboardingTour.starts[index]
            precondition(OnboardingTour.at(start).index == index)
            precondition(OnboardingTour.at(start + example.duration - 0.001).index == index)
            let empty = OnboardingTour.Frame(example: example, clock: 0)
            precondition(empty.message == example.retained)
            precondition(empty.words.isEmpty)
            let transcriptionStart = example.listeningEnd / example.speed
            let decoding = OnboardingTour.Frame(example: example, clock: transcriptionStart + 0.001)
            precondition(decoding.transcribing && !decoding.listening && !decoding.landed)
            precondition(decoding.message == example.retained)
            precondition(OnboardingTour.Frame(example: example, clock: transcriptionStart + 2.0 / 3 - 0.001).transcribing)
            let delivered = OnboardingTour.Frame(example: example, clock: transcriptionStart + 2.0 / 3 + 0.001)
            precondition(delivered.landed && !delivered.transcribing)
            let end = OnboardingTour.Frame(example: example, clock: example.duration)
            precondition(end.message == example.result)
            precondition(end.words == example.spoken)
            precondition(end.speechOpacity(at: example.spoken.count + 1) == 1)
            precondition(empty.speechOpacity(at: 0) == 0)
            precondition(empty.spotlightAmount == 0 && end.spotlightAmount == 0)
            let halfOut = OnboardingTour.Frame(example: example, clock: example.duration - 0.25)
            precondition(abs(halfOut.spotlightAmount - 0.5) < 0.0001)
            let dimStart = ((example.kind == .slack ? 2.3 : example.learned != nil ? 3.0 : 2.4) + example.addedDelay) / example.speed
            precondition(abs(OnboardingTour.Frame(example: example, clock: dimStart + 0.25).spotlightAmount - 0.5) < 0.0001)
            let fading = OnboardingTour.Frame(example: example, clock: (0.25 + 0.95 * 0.5 / Double(example.spoken.count + 3)) / example.speed)
            precondition(fading.speechOpacity(at: 0) > 0 && fading.speechOpacity(at: 0) < 1)
            precondition(example.highlights.allSatisfy { example.result.contains($0) })
            precondition(example.speechHighlights.allSatisfy { example.spoken.contains($0) })
            if example.section == 1 {
                precondition(!example.speechHighlights.isEmpty)
                let sourceContext = example.speechHighlights.reduce(example.spoken) { $0.replacingOccurrences(of: $1, with: "") }
                let outputContext = example.highlights.reduce(example.result) { $0.replacingOccurrences(of: $1, with: "") }
                precondition(sourceContext.split(separator: " ") == outputContext.split(separator: " "),
                             "Speech and result must leave exactly the same unhighlighted context: \(example.spoken)")
            }
        }
        let slack = examples.first { $0.kind == .slack }!
        let dimmed = slack.spoken.enumerated().filter { slack.replacedSpeechCharacters.contains($0.offset) }.map { String($0.element) }.joined()
        precondition(dimmed == "Siobhan,")
        let times = examples.first { $0.spoken.hasPrefix("Standup") }!
        let dimmedTimes = times.spoken.enumerated().filter { times.replacedSpeechCharacters.contains($0.offset) }.map { String($0.element) }.joined()
        precondition(dimmedTimes == "nine fifteen AM,four thirty PM.")
        precondition(examples[6].speechHighlights == ["December thirty first, twenty twenty six."])
        for example in examples {
            let lines = example.code.map(\.text)
            let syntax = TourYAML.highlight(lines)
            precondition(zip(lines, syntax).allSatisfy { line, tokens in tokens.map(\.text).joined() == line })
        }
        let syntax = TourYAML.highlight(["  offer: true # optional", "  prompt: |", "    Keep: # literal text", "  key: s", "  replace: '[#$1](https://example.com)'", "  regex: '/\\bPR\\s*#?(\\d+)\\b/'"])
        precondition(syntax[0].contains { $0.text == "offer" && $0.tone == .key })
        precondition(syntax[0].contains { $0.text == "true" && $0.tone == .literal })
        precondition(syntax[0].last!.tone == .comment)
        precondition(syntax[2].count == 1 && syntax[2][0].tone == .string)
        precondition(syntax[3].contains { $0.text == "key" && $0.tone == .key })
        precondition(syntax[4].last!.text == "'[#$1](https://example.com)'" && syntax[4].last!.tone == .string)
        precondition(!syntax[5].contains { $0.tone == .comment })
        precondition(slack.heading == "Enrich your dictation with scripts")
        precondition(examples[4].headingTerm == "replacements")
        precondition(examples.last!.headingTerm == "prompts")
        for example in examples where example.section == 1 {
            let start = OnboardingTour.Frame(example: example, clock: 0)
            let end = OnboardingTour.Frame(example: example, clock: example.listeningEnd / example.speed)
            precondition(start.revealOpacity(at: 0, count: example.headingTerm.count) == 0)
            precondition(end.revealOpacity(at: example.headingTerm.count - 1, count: example.headingTerm.count) == 1)
        }
        let offered = OnboardingTour.Frame(example: slack, clock: 2.5 + slack.addedDelay)
        precondition(offered.offering && !offered.mapped)
        precondition(offered.message.contains("Siobhan"))
        precondition(OnboardingTour.Frame(example: slack, clock: 3.8 + slack.addedDelay).pressingKey)
        precondition(OnboardingTour.Frame(example: slack, clock: 4.5 + slack.addedDelay).message.contains("@Sio"))
        for beat in stride(from: 2.8, through: 6.0, by: 0.05) {
            precondition(OnboardingTour.Frame(example: slack, clock: beat + slack.addedDelay).spotlightAmount > 0.999)
        }
        for example in examples where example.learned != nil {
            precondition(OnboardingTour.Frame(example: example, clock: (4 + example.addedDelay) / example.speed).learning)
            precondition(OnboardingTour.Frame(example: example, clock: (5.5 + example.addedDelay) / example.speed).pressingKey)
            precondition(!OnboardingTour.Frame(example: example, clock: (6.5 + example.addedDelay) / example.speed).learning)
        }
        for section in 0...1 {
            let index = OnboardingTour.at(OnboardingTour.sectionStart(section)).index
            precondition(examples[index].section == section)
        }
        // The demonstration must not promise rewrites the shipped scripts do
        // not make. Money follows the existing number-normalization stage.
        for example in examples where example.kind == .script {
            let command = example.code.first { $0.text.contains("command:") }!.text
                .components(separatedBy: "command: ")[1]
            var input = example.spoken
            if command.contains("money") { input = try run("built-in/transforms/numbers/en.py", input) }
            let actual = try run(command.replacingOccurrences(of: "built-in/", with: "built-in/transforms/"), input)
            precondition(actual == example.result, "\(example.spoken): \(actual) != \(example.result)")
        }
        let priorities = examples.first { $0.code.first?.text == "- name: priorities" }!
        let rules = try priorities.code.dropFirst(2).map { line -> (NSRegularExpression, String) in
            let parts = line.text.components(separatedBy: "'")
            return (try NSRegularExpression(pattern: String(parts[1].dropFirst().dropLast())),
                    line.text.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")[0])
        }
        func prioritiesOutput(_ input: String) -> String {
            rules.reduce(input) { text, rule in
                rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
            }
        }
        precondition(prioritiesOutput(priorities.spoken) == priorities.result)
        for keep in ["P0 P1 P2", "up one level", "top two", "P twenty", "P onefold", "phone zero"] {
            precondition(prioritiesOutput(keep) == keep)
        }
        precondition(OnboardingTour.highlightsTotal > 30 && OnboardingTour.highlightsTotal < 33)
        var reelTime = 0.0
        for index in OnboardingTour.highlightScenes {
            let midpoint = reelTime + examples[index].duration / 2
            precondition(OnboardingTour.at(OnboardingTour.highlightTime(midpoint)).index == index)
            reelTime += examples[index].duration
        }
        precondition(OnboardingTour.at(OnboardingTour.highlightTime(-1)).index == 2)
        precondition(OnboardingTour.at(OnboardingTour.highlightTime(reelTime + 1)).index == 11)
        print("PASS: 12 tour scenes, README highlights, continuous Slack dim, priority regex and keep cases, 4 real script examples")
    }
    static func run(_ script: String, _ text: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PARROTFLOW_PROTOCOL")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return String(decoding: result, as: UTF8.self)
    }
}
