import Foundation

/// Deterministic demo data and timing. Nothing in this tour runs a transform,
/// records audio, saves vocabulary, or sends the illustrated message.
enum OnboardingTour {
    enum Kind { case vocabulary, replacement, script, prompt, slack }
    struct CodeLine {
        let text: String
        var mapping = false
        var offer = false
    }
    struct Example {
        let kind: Kind
        let spoken: String
        let result: String
        var highlights: [String] = []
        var speechHighlights: [String] = []
        var code: [CodeLine] = []
        var file = "config.yaml"
        var learned: LearnExample?
        var retained = ""

        var section: Int {
            kind == .vocabulary ? 0 : 1
        }
        var heading: String {
            switch kind {
            case .vocabulary: return "The right term in the right context."
            default: return "Enrich your dictation with \(headingTerm)"
            }
        }
        var headingTerm: String {
            switch kind {
            case .replacement: return "replacements"
            case .prompt: return "prompts"
            case .script, .slack: return "scripts"
            case .vocabulary: return ""
            }
        }
        var speed: Double { kind == .vocabulary ? 1.5 / 1.25 : 1 }
        // Vocabulary's clock already slows its reveal by 25%; don't apply
        // the same slowdown twice. Other scenes slow only their speech.
        var revealDuration: TimeInterval { 0.95 * (kind == .vocabulary ? 1 : 1.25) }
        var listeningEnd: TimeInterval { 1.4 + revealDuration - 0.95 }
        var addedDelay: TimeInterval { listeningEnd - 1.4 + speed / 3 }
        var duration: TimeInterval { ((learned != nil ? 8 : kind == .slack ? 8.3 : 5.8) + addedDelay) / speed }

        /// Semantic source phrases, including unchanged words inside a date or
        /// time. A token diff cannot establish these correspondences.
        var replacedSpeechCharacters: Set<Int> {
            var indices = Set<Int>()
            for phrase in speechHighlights {
                guard let range = spoken.range(of: phrase) else { continue }
                let offset = spoken.distance(from: spoken.startIndex, to: range.lowerBound)
                indices.formUnion(offset..<(offset + phrase.count))
            }
            return indices
        }
    }
    struct LearnExample {
        let heard: String
        let term: String
        let before: String
        let after: String
    }
    static func script(_ name: String, _ spoken: String, _ result: String, _ highlights: [String], _ source: [String]) -> Example {
        Example(kind: .script, spoken: spoken, result: result, highlights: highlights, speechHighlights: source, code: [
            .init(text: "- name: \(name)_en"),
            .init(text: "  command: built-in/\(name)/en.py", mapping: true),
            .init(text: "  returns: json"),
        ])
    }
    static let examples: [Example] = [
        .init(kind: .vocabulary, spoken: "My teammate Mick is a software engineer.",
              result: "My teammate Mik is a software engineer.", highlights: ["Mik"], speechHighlights: ["Mick"],
              learned: .init(heard: "Mick", term: "Mik", before: "My teammate", after: " is a software engineer.")),
        .init(kind: .vocabulary, spoken: "My friend Mick plays the guitar.",
              result: "My friend Mick plays the guitar.", highlights: ["Mick"], speechHighlights: ["Mick"],
              learned: .init(heard: "Mik", term: "Mick", before: "My friend", after: " plays the guitar.")),
        .init(kind: .vocabulary, spoken: "Mik is writing code.", result: "Mik is writing code.", highlights: ["Mik"], speechHighlights: ["Mik"]),
        .init(kind: .vocabulary, spoken: "Mick is a musician.",
              result: "Mik is writing code. Mick is a musician.", highlights: ["Mick"], speechHighlights: ["Mick"], retained: "Mik is writing code. "),
        .init(kind: .replacement, spoken: "Can you review PR 478?", result: "Can you review #478?", highlights: ["#478?"], speechHighlights: ["PR 478?"], code: [
            .init(text: "- name: github_refs"),
            .init(text: "  replace:", mapping: true),
            .init(text: "    '[#$1](https://github.com/a/b/pull/$1)':", mapping: true),
            .init(text: #"      - '/\bPR\s*#?(\d+)\b/'"#, mapping: true),
        ]),
        .init(kind: .slack, spoken: "Hey Siobhan, can you review #478?", result: "Hey @Sio, can you review #478?", highlights: ["@Sio,"], speechHighlights: ["Siobhan,"], code: [
            .init(text: "- name: slack_mentions"),
            .init(text: "  offer: true", offer: true),
            .init(text: "  key: s", offer: true),
            .init(text: "  command: slack_mentions.py", mapping: true),
            .init(text: ""),
            .init(text: "# slack_mentions.py · excerpt"),
            .init(text: "ROSTER = {"),
            .init(text: "  \"Siobhan\": \"@Sio\"", mapping: true),
            .init(text: "}"),
        ]),
        script("dates", "The deadline is December thirty first, twenty twenty six.", "The deadline is December 31, 2026.", ["December", "31,", "2026."], ["December thirty first, twenty twenty six."]),
        script("dates", "Standup at nine fifteen AM, demo at four thirty PM.", "Standup at 9:15 AM, demo at 4:30 PM.", ["9:15", "AM,", "4:30", "PM."], ["nine fifteen AM,", "four thirty PM."]),
        script("money", "The budget is twelve thousand five hundred dollars.", "The budget is $12500.", ["$12500."], ["twelve thousand five hundred dollars."]),
        script("money", "It costs forty nine dollars and ninety nine cents.", "It costs $49.99.", ["$49.99."], ["forty nine dollars and ninety nine cents."]),
        .init(kind: .replacement,
              spoken: "Outage P zero, login P one, polish P two.",
              result: "Outage P0, login P1, polish P2.",
              highlights: ["P0,", "P1,", "P2."],
              speechHighlights: ["P zero,", "P one,", "P two."], code: [
            .init(text: "- name: priorities"),
            .init(text: "  replace:", mapping: true),
            .init(text: #"    P0: ['/\bP\s+zero\b/']"#, mapping: true),
            .init(text: #"    P1: ['/\bP\s+one\b/']"#, mapping: true),
            .init(text: #"    P2: ['/\bP\s+two\b/']"#, mapping: true),
        ]),
        .init(kind: .prompt, spoken: "I think its ready.", result: "I think it’s ready.", highlights: ["it’s"], speechHighlights: ["its"], code: [
            .init(text: "- name: grammar"),
            .init(text: "  prompt: |", mapping: true),
            .init(text: "    Correct grammar and punctuation.", mapping: true),
            .init(text: "    Keep the speaker’s wording.", mapping: true),
            .init(text: "    Return only the corrected text.", mapping: true),
        ]),
    ]
    static let starts: [TimeInterval] = examples.indices.map { index in
        examples.prefix(index).reduce(0) { $0 + $1.duration }
    }
    static let total = examples.reduce(0) { $0 + $1.duration }
    // README reel: contextual vocabulary, replacement, script, then prompt.
    // Keep complete scenes at their native pace; the install tour stays intact.
    static let highlightScenes = [2, 3, 4, 5, 11]
    static let highlightsTotal = highlightScenes.reduce(0.0) { $0 + examples[$1].duration }
    static func highlightTime(_ elapsed: TimeInterval) -> TimeInterval {
        var remaining = max(0, elapsed)
        for index in highlightScenes {
            if remaining < examples[index].duration {
                return starts[index] + remaining
            }
            remaining -= examples[index].duration
        }
        let last = highlightScenes.last!
        return starts[last] + examples[last].duration - 0.000001
    }
    /// The install flow uses the same playback clock as the visible tour.
    /// Failures must reach Retry even when playback is paused. Skip/Finish
    /// separately advance to setup status; neither closes or cancels setup.
    static func shouldFinishSetupTour(elapsed: TimeInterval, paused: Bool,
                                     downloadsReady: Bool, blockingFailure: Bool) -> Bool {
        blockingFailure || (!paused && elapsed >= total && downloadsReady)
    }
    static func at(_ elapsed: TimeInterval) -> (index: Int, clock: TimeInterval) {
        let index = starts.lastIndex(where: { $0 <= max(0, elapsed) }) ?? 0
        return (index, min(examples[index].duration, max(0, elapsed - starts[index])))
    }
    static func sectionStart(_ section: Int) -> TimeInterval {
        starts[examples.firstIndex(where: { $0.section == section }) ?? 0]
    }

    struct Frame {
        let example: Example
        /// Choreography time, scaled once for every vocabulary beat.
        let clock: TimeInterval
        init(example: Example, clock: TimeInterval) {
            self.example = example
            self.clock = clock * example.speed
        }
        var speechProgress: Double { min(1, max(0, (clock - 0.25) / example.revealDuration)) }
        var beatClock: TimeInterval { clock - example.addedDelay }
        func speechOpacity(at index: Int) -> Double {
            revealOpacity(at: index, count: example.spoken.count)
        }
        func revealOpacity(at index: Int, count: Int) -> Double {
            let amount = min(1, max(0, (speechProgress * Double(count + 7) - Double(index)) / 6))
            return amount * amount * (3 - 2 * amount)
        }
        var listening: Bool { clock >= 0.25 && clock < example.listeningEnd }
        // Keep this interval at a real two thirds of a second even in the faster
        // vocabulary scenes, whose choreography clock is scaled.
        var landingTime: TimeInterval { example.listeningEnd + 2 * example.speed / 3 }
        var transcribing: Bool { clock >= example.listeningEnd && clock < landingTime }
        var landed: Bool { clock >= landingTime }
        var offering: Bool { example.kind == .slack && beatClock >= 2.3 }
        var learning: Bool { example.learned != nil && beatClock >= 3.4 && beatClock < 6.2 }
        var pressingKey: Bool { example.learned != nil ? beatClock >= 5.3 && beatClock < 6.2 : offering && beatClock >= 3.5 && beatClock < 4.3 }
        var mapped: Bool { landed && (example.kind == .slack ? beatClock >= 4.3 : example.learned != nil ? beatClock >= 3 : true) }
        var spotlight: Bool { learning || offering || (!example.highlights.isEmpty && mapped && beatClock >= 2.4) }
        var spotlightAmount: Double {
            let start = ((example.kind == .slack ? 2.3 : example.learned != nil ? 3 : 2.4) + example.addedDelay) / example.speed
            let elapsed = clock / example.speed
            func ease(_ value: Double) -> Double {
                let t = min(1, max(0, value))
                return t * t * (3 - 2 * t)
            }
            return ease((elapsed - start) / 0.5) * ease((example.duration - elapsed) / 0.5)
        }
        var words: String {
            String(example.spoken.prefix(Int(speechProgress * Double(example.spoken.count))))
        }
        var message: String {
            guard landed else { return example.retained }
            if mapped { return example.result }
            if let learn = example.learned { return "\(learn.before) \(learn.heard)\(learn.after)" }
            return example.spoken
        }
    }
}

/// A small, lossless lexer for the tour's YAML excerpts. Quotes are consumed
/// before punctuation, so URL colons and regex hashes remain string content.
enum TourYAML {
    enum Tone { case plain, key, string, literal, punctuation, comment }
    struct Token { let text: String; let tone: Tone }

    static func highlight(_ lines: [String]) -> [[Token]] {
        var blockIndent: Int?
        return lines.map { line in
            let indent = line.prefix(while: { $0 == " " }).count
            if let parent = blockIndent, indent > parent || line.isEmpty {
                return [Token(text: line, tone: .string)]
            }
            blockIndent = nil
            let chars = Array(line)
            var tokens: [Token] = []
            var i = 0
            var value = false
            func append(_ start: Int, _ end: Int, _ tone: Tone) {
                tokens.append(Token(text: String(chars[start..<end]), tone: tone))
            }
            while i < chars.count {
                let start = i
                let c = chars[i]
                if c.isWhitespace {
                    while i < chars.count && chars[i].isWhitespace { i += 1 }
                    append(start, i, .plain)
                } else if c == "#" {
                    append(i, chars.count, .comment)
                    break
                } else if c == "'" || c == "\"" {
                    i += 1
                    while i < chars.count {
                        if c == "\"" && chars[i] == "\\" { i = min(chars.count, i + 2); continue }
                        if chars[i] == c {
                            i += 1
                            if c == "'" && i < chars.count && chars[i] == "'" { i += 1; continue }
                            break
                        }
                        i += 1
                    }
                    append(start, i, .string)
                } else if ":{}[],=|>".contains(c) || (c == "-" && (i + 1 == chars.count || chars[i + 1].isWhitespace)) {
                    if c == ":" { value = true }
                    if (c == "|" || c == ">") && value { blockIndent = indent }
                    i += 1
                    append(start, i, .punctuation)
                } else {
                    while i < chars.count && !chars[i].isWhitespace && !":{}[],=|>".contains(chars[i]) { i += 1 }
                    let word = String(chars[start..<i])
                    let next = chars[i...].first(where: { !$0.isWhitespace })
                    let tone: Tone = !value && next == ":" ? .key
                        : ["true", "false", "null", "~"].contains(word) || Double(word) != nil ? .literal : .string
                    append(start, i, tone)
                }
            }
            return tokens
        }
    }
}
