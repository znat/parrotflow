import Foundation
import NaturalLanguage

/// The text side of `ClaudeVoice`: what a hook event or a written answer
/// sounds like. No audio, no network, so `--claude-voice-test` can score it.
enum ClaudeSpeakable {

    // MARK: - Written answer → speakable text

    private static func rule(_ pattern: String, _ template: String) -> (NSRegularExpression, String)? {
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    /// In order. Code and tables go first, so nothing below rewrites inside them.
    private static let rules: [(NSRegularExpression, String)] = [
        rule(#"(?s)```.*?(```|$)"#, "\n"),
        rule(#"(?m)^\s*\|.*$"#, ""),
        rule(#"(?m)^\s*>\s?"#, ""),
        rule(#"(?m)^\s*#{1,6}\s+"#, ""),
        rule(#"(?m)^\s*(?:[-*+]|\d+[.)])\s+"#, ""),
        rule(#"https?://github\.com/[\w.-]+/([\w.-]+)/pull/(\d+)[^\s)\]]*"#, "PR $2 in $1"),
        rule(#"https?://github\.com/[\w.-]+/([\w.-]+)/issues/(\d+)[^\s)\]]*"#, "issue $2 in $1"),
        rule(#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        rule(#"https?://(?:www\.)?([^/\s)\]]+)[^\s)\]]*"#, "a link on $1"),
        rule(#"(?<![\w/])[\w.-]+/([\w.-]+)#(\d+)\b"#, "PR $2 in $1"),
        rule(#"(?<![\w&])#(\d+)\b"#, "number $1"),
        rule(#"`([^`\n]*)`"#, "$1"),
        // A path with a file name at the end: keep the file name.
        rule(#"(?<![\w])(?:~|\.{1,2})?/?(?:[\w@.+-]+/)+([\w@+-]+\.[A-Za-z0-9]{1,8})\b"#, "$1"),
        // An absolute or home path to a folder: keep its last part.
        rule(#"(?<![\w])(?:~/|/)(?:[\w@.+-]+(?: [\w@.+-]+)*/)*([\w@.+-]+)/?"#, "$1"),
        rule(#"\b([\w+-]+\.[A-Za-z]{1,8}):\d+(?:-\d+)?\b"#, "$1"),
        rule(#"\*\*|__|(?<!\w)\*(?=\S)|(?<=\S)\*(?!\w)"#, ""),
        rule(#"\s*(?:→|->|=>)\s*"#, " to "),
        rule(#"\s*[≈~](?=\s*\d)"#, " about "),
        rule(#"\s&\s"#, " and "),
        rule(#"[✓✗⚠︎•·]"#, ""),
        // Commit hashes say nothing out loud.
        rule(#"\s*\(?(?:\b(?:at|as|in|on|from)\s+)?\bcommit\s+(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b\)?"#, ""),
        rule(#"\s*\((?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\)"#, ""),
        rule(#"\s+(?:as|at)\s+(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b"#, ""),
        rule(#"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b"#, ""),
        // Times as people say them: no seconds, no leading zero.
        rule(#"\b(\d{1,2}):(\d{2}):\d{2}\b"#, "$1:$2"),
        rule(#"\b0(\d):(\d{2})\b"#, "$1:$2"),
    ].compactMap { $0 }

    /// Units in words. A language with no table keeps the symbols.
    private static let units: [String: [(NSRegularExpression, String)]] = [
        "en": unitRules(["milliseconds", "seconds", "gigabytes", "megabytes", "kilobytes", "percent"]),
        "fr": unitRules(["millisecondes", "secondes", "gigaoctets", "mégaoctets", "kilooctets", "pour cent"]),
    ]

    private static func unitRules(_ words: [String]) -> [(NSRegularExpression, String)] {
        zip([#"(\d)\s?ms\b"#, #"(\d)\s?s\b(?!-)"#, #"(\d)\s?GB\b"#, #"(\d)\s?MB\b"#, #"(\d)\s?KB\b"#,
             #"(\d)\s?%"#], words).compactMap { rule($0, "$1 " + $1) }
    }

    private static let isoDate = try? NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#)

    /// "2026-11-06" → "November 6" or "6 novembre", with the year only when
    /// it is not this one.
    static func spokenDates(_ text: String, now: Date = Date(), language: String = "en") -> String {
        guard let isoDate else { return text }
        let calendar = Calendar(identifier: .gregorian)
        let thisYear = calendar.component(.year, from: now)
        let locale = Locale(identifier: language)
        let format = DateFormatter()
        format.locale = locale
        format.calendar = calendar
        var out = text
        for match in isoDate.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out),
                  let year = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                  let month = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
                  let day = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) }),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
            else { continue }
            format.setLocalizedDateFormatFromTemplate(year == thisYear ? "MMMMd" : "yMMMMd")
            out.replaceSubrange(whole, with: format.string(from: date))
        }
        return out
    }

    /// Markdown in, sentences out. Lists, headings and paragraphs each become
    /// a sentence, so the voice pauses where the eye would.
    static func clean(_ text: String, language: String = "en") -> String {
        var out = spokenDates(text, language: language)
        for (expression, template) in rules + (units[language] ?? []) {
            out = expression.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template
            )
        }
        let sentences = out
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                guard let last = line.last, !".!?:;,".contains(last) else { return line }
                return line + "."
            }
        return sentences.joined(separator: " ")
            .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Not after a colon: "Update from parrotflow:" and the sentence it
    /// introduces are one call to the voice, not two cold starts.
    static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(
            of: #"(?<=[.!?])\s+(?=[\p{Lu}0-9"'(«])"#, with: "\u{1}", options: .regularExpression
        )
        .components(separatedBy: "\u{1}")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    /// Plain ASCII punctuation for the voice. PocketTTS on the Neural Engine
    /// (`ane-state`) never finished a sentence with a curly apostrophe in it,
    /// measured 2026-11-06: `I’m` hung past 60 s, `I'm` took 1.7 s.
    static func speakable(_ text: String) -> String {
        var out = text
        for (from, to) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{02BC}", "'"), ("\u{201C}", "\""),
                           ("\u{201D}", "\""), ("\u{2026}", "..."), ("\u{2014}", ", "), ("\u{2013}", ", "),
                           ("\u{00A0}", " ")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    /// The language a request is written in, as a code like "fr". Nil for a
    /// line too short to tell.
    /// Only plain words count, and any language but English needs 0.8: on
    /// 400 real prompts, paths and URLs read as Dutch or Indonesian at
    /// 0.62-0.95 (2026-11-06).
    static func language(of text: String) -> String? {
        let letters = { (word: Substring) in word.allSatisfy { $0.isLetter || "'’-".contains($0) } }
        let plain = text.split(whereSeparator: \.isWhitespace).filter { word in
            letters(word) || (",.?!;:".contains(word.last ?? " ") && letters(word.dropLast()))
        }.joined(separator: " ")
        guard plain.split(separator: " ").count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(plain)
        guard let (found, odds) = recognizer.languageHypotheses(withMaximum: 1).first,
              odds >= (found == .english ? 0.6 : 0.8) else { return nil }
        return found.rawValue
    }

    /// "fr" → "French", for a prompt.
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Short enough to say as it is, without a model call.
    static func isShort(_ cleaned: String) -> Bool {
        cleaned.count <= 220 && sentences(cleaned).count <= 3
    }

    /// What is said when the model is not there: the first two sentences.
    static func truncated(_ cleaned: String) -> String {
        sentences(cleaned).prefix(2).joined(separator: " ")
    }

    // MARK: - Hook event → progress line

    enum Kind: String { case command, edit, read, web, agent, question, other }

    struct Line: Equatable {
        var text: String
        var kind: Kind
        /// Said even when progress lines are throttled.
        var urgent = false
    }

    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The line a `PreToolUse` event is worth, or nil for a tool that is
    /// bookkeeping rather than work.
    static func progress(tool: String, input: [String: Any]) -> Line? {
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func file() -> String { string("file_path").map(basename) ?? string("notebook_path").map(basename) ?? "a file" }
        switch tool {
        case "Bash":
            let said = string("description").map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            return Line(text: said.map(firstPerson) ?? "I'm running a command", kind: .command)
        case "Edit", "MultiEdit", "NotebookEdit":
            return Line(text: "I'm editing \(file())", kind: .edit)
        case "Write":
            return Line(text: "I'm writing \(file())", kind: .edit)
        case "Read", "Grep", "Glob", "LS":
            return Line(text: "I'm looking through the code", kind: .read)
        case "WebSearch":
            return Line(text: "I'm searching the web", kind: .web)
        case "WebFetch":
            return Line(text: "I'm reading a web page", kind: .web)
        case "Task", "Agent":
            let said = string("description").map { lowercasedFirst($0) }
            return Line(text: said.map { "I'm asking an agent to \($0)" } ?? "I'm starting an agent", kind: .agent)
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return Line(text: first.map { "Quick question. \($0)" } ?? "I have a question for you.",
                        kind: .question, urgent: true)
        case "ExitPlanMode":
            return Line(text: "The plan's ready when you want to look.", kind: .question, urgent: true)
        default:
            if tool.hasPrefix("mcp__"), tool.contains("Browser") || tool.contains("chrome") {
                return Line(text: "I'm using the browser", kind: .web)
            }
            return nil
        }
    }

    /// "Check the dev app" → "I'm checking the dev app". Command
    /// descriptions are imperatives, which sound like a sign being read out.
    static func firstPerson(_ description: String) -> String {
        let words = description.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = words.first?.lowercased(), verb.allSatisfy(\.isLetter) else { return description }
        let rest = words.count > 1 ? " " + words[1] : ""
        return "I'm " + gerund(verb) + rest
    }

    private static let doubled: Set<String> = [
        "run", "get", "set", "put", "stop", "cut", "plan", "ship", "drop", "map", "swap", "tag", "log",
        "grep", "sit", "trim", "wrap", "skip", "strip", "commit", "rerun", "submit", "begin",
    ]

    static func gerund(_ verb: String) -> String {
        if verb.hasSuffix("ing") { return verb }
        if doubled.contains(verb), let last = verb.last { return verb + String(last) + "ing" }
        if verb.hasSuffix("ie") { return String(verb.dropLast(2)) + "ying" }
        if verb.hasSuffix("e"), !verb.hasSuffix("ee"), !verb.hasSuffix("ye"), !verb.hasSuffix("oe"), verb.count > 2 {
            return String(verb.dropLast()) + "ing"
        }
        return verb + "ing"
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static let secrets: [(NSRegularExpression, String)] = [
        rule(#"(?i)\bbearer\s+[^\s'"]+"#, "Bearer <redacted>"),
        rule(#"(?i)\b([\w-]*(?:token|secret|passw(?:or)?d|api[_-]?key)[\w-]*)(\s*[:=]\s*|\s+)(['"]?)[^\s'"]+\3"#,
             "$1$2<redacted>"),
        rule(#"\b(?:sk|pk|rk|ghp|gho|ghs|ghu|github_pat|xox[abpr]|AKIA|AIza)[-_A-Za-z0-9]{8,}"#, "<redacted>"),
        rule(#"\b[A-Za-z0-9+/_-]{32,}={0,2}"#, "<redacted>"),
        rule(#"(https?://[^\s?#'"]+)[?#][^\s'"]*"#, "$1"),
    ].compactMap { $0 }

    /// What a command or URL looks like with its secrets taken out, before
    /// it is sent to a model that may not be on this Mac.
    static func redacted(_ text: String) -> String {
        var out = text
        for (expression, template) in secrets {
            out = expression.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template
            )
        }
        return out
    }

    /// A `Notification` worth saying. The idle reminder is not: it arrives a
    /// minute after an answer that was already spoken.
    static func notification(_ message: String) -> String? {
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !said.lowercased().contains("waiting for your input") else { return nil }
        return clean(said)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
