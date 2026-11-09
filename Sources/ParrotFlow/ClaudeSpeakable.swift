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
        rule(#"(?<![\w])(?:~/|/)(?:[\w@.+-]+(?: [A-Z0-9][\w@.+-]*)*/)*([\w@.+-]+)/?"#, "$1"),
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

    /// What the model is sent: the request, then the reply and the recap.
    static func rewriteInput(
        request: String?, reply: String, recap: String?, earlier: Earlier? = nil, language: String = "en",
        opening: Int? = nil
    ) -> String {
        var parts = ["Language: " + languageName(language)]
        if let opening { parts.append("Opening: \(opening)") }
        if let earlier {
            if let prompt = earlier.prompt, !prompt.isEmpty {
                parts.append("Earlier request: " + String(redacted(clean(prompt)).prefix(600)))
            }
            let said = earlier.recap.map { clean($0, language: language) } ?? clean(earlier.answer, language: language)
            if !said.isEmpty { parts.append("Earlier reply: " + String(redacted(said).prefix(1500))) }
        }
        if let request, !request.isEmpty { parts.append("Request: " + String(redacted(clean(request)).prefix(800))) }
        if !reply.isEmpty { parts.append("Reply: " + String(redacted(reply).prefix(6000))) }
        if let recap, !recap.isEmpty { parts.append("Recap: " + String(redacted(recap).prefix(800))) }
        return parts.joined(separator: "\n\n")
    }

    /// A rewrite that ran long keeps whole sentences up to about `limit`
    /// characters, at most `count`. A semicolon counts as a sentence end.
    static func capped(_ said: String, limit: Int = 300, count: Int = 3) -> String {
        let parts = sentences(said.replacingOccurrences(of: #";\s+"#, with: ". ", options: .regularExpression))
        var kept: [String] = []
        var length = 0
        for part in parts.prefix(count) {
            if !kept.isEmpty, length + part.count > limit { break }
            kept.append(part.prefix(1).uppercased() + part.dropFirst())
            length += part.count + 1
        }
        return capitalizedSentences(kept.joined(separator: " "))
    }

    /// "a term. my examples" → "a term. My examples": the split above only
    /// cuts before a capital, so a lowercase start stays inside a sentence.
    static func capitalizedSentences(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(?<=[.!?]\s)\p{Ll}"#) else { return text }
        var out = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: out[range].uppercased())
        }
        return out
    }

    /// "Done" → "Done." so the voice pauses before the facts.
    static func spokenOpener(_ opener: String?) -> String {
        let said = clean(opener ?? "").trimmingCharacters(in: .whitespaces)
        guard let last = said.last else { return "" }
        return last.isLetter || last.isNumber ? said + "." : said
    }

    /// The base tone, then this moment's shift.
    /// Gemini read "natural, conversational" as a cue to add "um"s and false
    /// starts the text did not have, in English and French (2026-11-06).
    static let fluent = "Say exactly the words written, fluently: no added fillers, hesitations, "
        + "false starts, sighs or laughs."

    static func instructions(base: String, shift: String?) -> String {
        guard let shift, !shift.isEmpty else { return base + " " + fluent }
        return base + " Right now: " + shift + ". " + fluent
    }

    private static let stopWords: Set<String> = Set(
        ("this that with from have will what when then they them their there were your just into also than "
            + "only about after before because which would could should being been does doing done here more "
            + "most some such very over "
            + "dans pour avec mais plus tout tous toute cette sont était être avoir fait faire comme aussi "
            + "encore très quand alors donc leur leurs elle elles nous vous ils sans sous entre depuis").split(separator: " ").map(String.init)
    )

    private static let wordPattern = try? NSRegularExpression(pattern: #"[\p{Ll}0-9][\p{Ll}0-9'.-]*"#)

    private static func contentWords(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let edges = CharacterSet(charactersIn: ".'-")
        let found = wordPattern?.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            .compactMap { Range($0.range, in: lower).map { String(lower[$0]).trimmingCharacters(in: edges) } }
            .filter { $0.count >= 4 } ?? []
        return Set(found).subtracting(stopWords)
    }

    /// The share of the output's content words that the input also has. A
    /// small model wrote "I fixed the crash", its prompt's own example, for
    /// four of ten long answers; those score 0.
    static func grounded(_ said: String, in source: String) -> Double {
        let out = contentWords(said)
        guard !out.isEmpty else { return 1 }
        return Double(out.intersection(contentWords(source)).count) / Double(out.count)
    }

    static let groundedFloor = 0.4

    /// A keep-mode result that grew is one the model added to; the original
    /// words are said instead.
    static func kept(_ said: String, original: String) -> String {
        said.isEmpty || said.count > original.count * 3 / 2 + 20 ? original : said
    }

    /// Reads the model's JSON. A short plain-text answer still gives the
    /// words, with no tone. Anything else gives an empty `say`.
    static func parseSpoken(_ raw: String)
        -> (say: String, tone: String?, opener: String?, task: String?, json: Bool) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        }
        let object = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        if let object = object as? [String: Any], let say = object["say"] as? String {
            let tone = (object["tone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let opener = (object["opener"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (say, tone?.isEmpty == false ? tone : nil, opener?.isEmpty == false ? opener : nil,
                    taskLabel(object["task"] as? String), true)
        }
        return (object == nil && isShort(text) ? text : "", nil, nil, nil, false)
    }

    /// Two or three plain words, lowercased. Anything else is no label.
    static func taskLabel(_ raw: String?) -> String? {
        let words = (raw ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!\n"))
            .split(separator: " ").map(String.init)
        guard (2...3).contains(words.count), words.allSatisfy(isPlainWord) else { return nil }
        return words.joined(separator: " ")
    }

    /// Letters, with an inner apostrophe or hyphen. Paths, numbers and tokens are not.
    private static func isPlainWord(_ word: String) -> Bool {
        guard word.count <= 20, word.first?.isLetter == true, word.last?.isLetter == true else { return false }
        return word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
    }

    private static let promptFillers: Set<String> = ["please", "thanks", "want", "need", "again", "merci"]

    /// Before the first answer gives a label: the first three content words of the request.
    static func taskWords(_ prompt: String?, skipping project: String = "") -> String? {
        var seen: [String] = []
        for token in (prompt ?? "").lowercased().split(whereSeparator: \.isWhitespace) {
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 4, isPlainWord(word), !stopWords.contains(word), !promptFillers.contains(word),
                  word != project.lowercased(), !seen.contains(word) else { continue }
            seen.append(word)
            if seen.count == 3 { break }
        }
        return seen.isEmpty ? nil : seen.joined(separator: " ")
    }

    /// "parrotflow · fixing the glow". A long folder keeps its start.
    static func sessionName(project: String, task: String?) -> String? {
        let folder = project.count > 24 ? String(project.prefix(23)) + "…" : project
        let parts = [folder, task ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// The request, and the session's title and latest result when known, for the reminder prompt.
    static func reminderInput(request: String, latest: String?, task: String? = nil, language: String = "en") -> String {
        var lines = ["Language: \(languageName(language))"]
        if let task, !task.isEmpty { lines.append("Task: \(String(redacted(clean(task)).prefix(300)))") }
        lines.append("Request: \(String(redacted(clean(request)).prefix(1500)))")
        if let latest, !latest.isEmpty { lines.append("Latest: \(String(redacted(clean(latest)).prefix(500)))") }
        return lines.joined(separator: "\n")
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
        replacing(text, secrets)
    }

    /// Every rule in `secrets`, but prose like "the token expired" is kept. A
    /// secret becomes a word the voice can say.
    private static let spokenSecrets: [(NSRegularExpression, String)] = [
        // The value: a digit, a sign inside it, or 8 characters. "bearer of bad news" is kept.
        rule(#"(?i)\bbearer\s+(?=[^\s'"]*\d|[^\s'"]*[^A-Za-z\s'".,;:!?]|[^\s'"]*[.,;:!?][^\s'".,;:!?]|[^\s'"]{7,}[^\s'".,;:!?])[^\s'"]*[^\s'".,;:!?]"#,
             "Bearer redacted"),
        rule(#"(https?://[^\s?#'"]+)[?#][^\s'"]*[^\s'".,;:!?]"#, "$1"),
        rule(#"(?i)\b([\w-]*(?:token|secret|passw(?:or)?d|api[_-]?key)[\w-]*)(\s*[:=]\s*)(['"]?)[^\s'"]*[^\s'".,;:!?]\3"#,
             "$1$2redacted"),
        // After a space, only a value shaped like a secret: "the token expired" is kept.
        rule(#"(?i)\b([\w-]*(?:token|secret|passw(?:or)?d|api[_-]?key)[\w-]*)(\s+)(['"]?)"#
             + #"(?=[^\s'"]*\d|[^\s'"]*[^\p{L}\s'".,;:!?]|[^\s'"]*[.,;:!?][^\s'".,;:!?]|[^\s'"]{7,}[^\s'".,;:!?])"#
             + #"[^\s'"]*[^\s'".,;:!?]\3"#, "$1$2redacted"),
        rule(#"\b(?:[spr]k[-_]|gh[posu]_|github_pat_|xox[abpr]-|AKIA|AIza)[-_A-Za-z0-9]{8,}"#, "redacted"),
        rule(#"\b(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{32,}={0,2}"#, "redacted"),
    ].compactMap { $0 }

    /// A line about to be said, and logged, with its secrets taken out. The
    /// remote voice is not on this Mac either.
    static func spokenRedacted(_ text: String) -> String {
        replacing(text, spokenSecrets)
    }

    private static func replacing(_ text: String, _ rules: [(NSRegularExpression, String)]) -> String {
        var out = text
        for (expression, template) in rules {
            out = expression.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template
            )
        }
        return out
    }

    /// The tool call, and what Claude wrote just before it, for the explain prompt.
    static func explainInput(
        tool: String, input: [String: Any], context: String?, task: String? = nil, language: String = "en",
        opening: Int? = nil, said: [String] = []
    ) -> String {
        var lines = ["Language: \(languageName(language))", "Tool: \(tool)"]
        if let opening { lines.append("Opening: \(opening)") }
        if let task, !task.isEmpty { lines.insert("Session task: \(String(redacted(clean(task)).prefix(400)))", at: 1) }
        for key in ["description", "command", "file_path", "pattern", "query", "url"] {
            guard var value = input[key] as? String, !value.isEmpty else { continue }
            if key == "file_path" { value = basename(value) }
            lines.append("\(key): \(String(redacted(value).prefix(600)))")
        }
        if let context, !context.isEmpty {
            lines.append("What the assistant just wrote: \(String(redacted(clean(context)).suffix(500)))")
        }
        if !said.isEmpty { lines.append((["Already said:"] + said.map { "- " + $0 }).joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    /// A `Notification` worth saying. The idle reminder is not: it arrives a
    /// minute after an answer that was already spoken.
    static func notification(_ message: String) -> String? {
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !said.lowercased().contains("waiting for your input") else { return nil }
        return clean(said)
    }

    // MARK: - Transcript → the turn that just ended

    struct TurnEnd: Equatable {
        /// Text written after the last tool call: the answer, not the
        /// "now checking X" lines between calls.
        var answer: String
        /// The desktop app's own two-sentence summary, when the turn has one.
        var recap: String?
        var ask: String?
        /// The last text block of the turn, wherever it sits: what Claude
        /// said just before the tool call now running.
        var latestText: String?
        /// What the person asked, at the start of the turn.
        var prompt: String?
        /// The turn before, so the model can tell what the request refers to.
        var earlier: Earlier?
    }

    struct Earlier: Equatable {
        var prompt: String?
        var answer: String
        var recap: String?
    }

    /// The newest summary in a session's transcript, across turns: the last
    /// wrap-up recap, else the last text Claude wrote. Read when a prompt is
    /// sent, so the turn it starts has nothing in it yet.
    static func latestSummary(transcript url: URL, tailBytes: Int = 512 * 1024) -> String? {
        tail(of: url, bytes: tailBytes).flatMap(latestSummary(lines:))
    }

    /// The session's title: the last one the person set, else the last one
    /// Claude Code wrote. Title lines can sit anywhere in the file.
    static func title(transcript url: URL) -> String? {
        func last(_ type: String) -> [String: Any]? {
            lastEntry(in: url, containing: #""type":"\#(type)""#) { $0["type"] as? String == type }
        }
        let named = last("custom-title")?["customTitle"] as? String
        let made = last("ai-title")?["aiTitle"] as? String
        return named?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? made?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The last line of a `.jsonl` file that holds `marker` and is a JSON
    /// object, found with a byte search from the end of the mapped file.
    static func lastEntry(in url: URL, containing marker: String,
                          where accept: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let needle = Data(marker.utf8)
        var upper = data.endIndex
        while let hit = data.range(of: needle, options: .backwards, in: data.startIndex..<upper) {
            let start = data[..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let end = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let entry = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any], accept(entry) {
                return entry
            }
            upper = start
        }
        return nil
    }

    /// The last `bytes` of a `.jsonl` file, as lines.
    static func tail(of url: URL, bytes: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        // The tail can start inside a character; that first line is cut anyway.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    static func latestSummary(lines: [String]) -> String? {
        var lastText: String?
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "assistant" else { continue }
            let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks.reversed() {
                if block["type"] as? String == "tool_use", (block["name"] as? String ?? "").hasSuffix("wrap_up"),
                   let recap = (block["input"] as? [String: Any])?["recap"] as? String, !recap.isEmpty {
                    return recap
                }
                if lastText == nil, block["type"] as? String == "text", let text = block["text"] as? String,
                   !text.isEmpty {
                    lastText = text
                }
            }
        }
        return lastText.map { String($0.prefix(600)) }
    }

    /// Reads the tail of a session's `.jsonl` and returns the last turn.
    static func lastTurn(transcript url: URL, tailBytes: Int = 512 * 1024) -> TurnEnd? {
        tail(of: url, bytes: tailBytes).flatMap(lastTurn(lines:))
    }

    static func lastTurn(lines: [String]) -> TurnEnd? {
        guard let (start, last) = turn(endingAt: lines.endIndex, in: lines) else { return nil }
        var ended = last
        if start > lines.startIndex, let (_, before) = turn(endingAt: start, in: lines) {
            ended.earlier = Earlier(prompt: before.prompt, answer: before.answer, recap: before.recap)
        }
        return ended
    }

    /// The turn whose lines end at `end`, and the index of its prompt line.
    private static func turn(endingAt end: Int, in lines: [String]) -> (Int, TurnEnd)? {
        var entries: [[String: Any]] = []
        var asked: String?
        var start = lines.startIndex
        for index in stride(from: end - 1, through: lines.startIndex, by: -1) {
            guard let data = lines[index].data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if isPrompt(entry) {
                let content = (entry["message"] as? [String: Any])?["content"]
                asked = content as? String ?? (content as? [[String: Any]])?
                    .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                start = index
                break
            }
            if entry["type"] as? String == "assistant" { entries.append(entry) }
        }
        guard !entries.isEmpty else { return nil }
        entries.reverse()

        var answer: [String] = []
        var recap: String?
        var ask: String?
        var latest: String?
        for entry in entries {
            let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String {
                        answer.append(text)
                        latest = text
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    if name.hasSuffix("wrap_up"), let input = block["input"] as? [String: Any] {
                        recap = (input["recap"] as? String)?.nilIfEmpty
                        ask = (input["ask"] as? String)?.nilIfEmpty
                    } else {
                        answer.removeAll()
                    }
                default: break
                }
            }
        }
        return (start, TurnEnd(answer: answer.joined(separator: "\n\n"), recap: recap, ask: ask, latestText: latest,
                               prompt: asked))
    }

    /// Whether a prompt came from the person. A finished background task and a
    /// message from another session arrive as prompts too, and fire
    /// `UserPromptSubmit` while the person works in another pane.
    static func typed(_ prompt: String) -> Bool {
        !["[SYSTEM NOTIFICATION", "<task-notification>", "Another Claude session sent a message:",
          "<agent-message", "<cross-session-message"].contains { prompt.hasPrefix($0) }
    }

    /// A line the person typed, as opposed to a tool result or a reminder the
    /// harness slipped in.
    private static func isPrompt(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return typed(text) }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return !blocks.contains { $0["type"] as? String == "tool_result" }
            && blocks.contains { $0["type"] as? String == "text" }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
