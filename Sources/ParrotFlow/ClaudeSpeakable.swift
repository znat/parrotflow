import Foundation

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
        rule(#"(?<![\w])(?:~/|/)(?:[\w@.+ -]+/)*([\w@.+-]+)/?"#, "$1"),
        rule(#"\b([\w+-]+\.[A-Za-z]{1,8}):\d+(?:-\d+)?\b"#, "$1"),
        rule(#"\*\*|__|(?<!\w)\*(?=\S)|(?<=\S)\*(?!\w)"#, ""),
        rule(#"\s*(?:→|->|=>)\s*"#, " to "),
        rule(#"\s*[≈~](?=\s*\d)"#, " about "),
        rule(#"\s&\s"#, " and "),
        rule(#"[✓✗⚠︎•·]"#, ""),
    ].compactMap { $0 }

    /// Markdown in, sentences out. Lists, headings and paragraphs each become
    /// a sentence, so the voice pauses where the eye would.
    static func clean(_ text: String) -> String {
        var out = text
        for (expression, template) in rules {
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

    static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(
            of: #"(?<=[.!?:])\s+(?=[A-Z0-9"'(])"#, with: "\u{1}", options: .regularExpression
        )
        .components(separatedBy: "\u{1}")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    /// Short enough to say as it is, without a model call.
    static func isShort(_ cleaned: String) -> Bool {
        cleaned.count <= 220 && sentences(cleaned).count <= 3
    }

    /// What is said when the model is not there: the first two sentences.
    static func truncated(_ cleaned: String) -> String {
        sentences(cleaned).prefix(2).joined(separator: " ")
    }

    enum Mode: String {
        /// A long reply: shorten it to what is worth hearing.
        case shorten
        /// A recap or a short reply: change person and tense only.
        case keep
    }

    /// The rewrite, and a short shift for how to say it. The base tone is not
    /// the model's to write: `speechTone` is sent as it is, with the shift after.
    static let rewritePrompt = """
        You turn a coding assistant's written reply into what it says out loud to the \
        developer it works with, who is not looking at the screen.

        The first line of the message is MODE: shorten or MODE: keep.

        Return JSON: {"say": "...", "tone": "..."}

        say, in both modes:
        - First person for what the assistant did or found: "I fixed the crash", \
        "I'm checking the log". Any other subject stays: "the app can't load it" \
        stays about the app, "CI is green" stays about CI.
        - Simple past or present. Never the present perfect, and never the passive: \
        not "The crash has been fixed", not "I've fixed the crash".
        - Talk the way a colleague talks: contractions, casual words, no formal phrasing.
        - Keep file names, PR numbers and command names as the reply wrote them.
        - No code, no lists, no markdown, no paths, no greetings.

        MODE: shorten
        - At most three short sentences and 50 words. Lead with the result, then \
        what the developer has to do or decide, if anything. Leave the rest out.

        MODE: keep
        - Keep every fact and every question, in the same order. Change only person, \
        tense and wording. Add nothing that is not in the text.

        tone: how this moment shifts a relaxed, friendly delivery, in at most 8 words. \
        For example "a little pleased", "calm, a little sorry", "curious", "easy, routine".
        """

    /// A shorten-mode result that ran long keeps whole sentences up to about
    /// `limit` characters, at most three. A semicolon counts as a sentence end.
    static func capped(_ said: String, limit: Int = 300) -> String {
        let parts = sentences(said.replacingOccurrences(of: #";\s+"#, with: ". ", options: .regularExpression))
        var kept: [String] = []
        var length = 0
        for part in parts.prefix(3) {
            if !kept.isEmpty, length + part.count > limit { break }
            let sentence = part.prefix(1).uppercased() + part.dropFirst()
            kept.append(sentence)
            length += part.count + 1
        }
        return kept.joined(separator: " ")
    }

    /// What the model is sent: the mode, then the text.
    static func rewriteInput(_ text: String, mode: Mode) -> String {
        "MODE: \(mode.rawValue)\n\n\(text)"
    }

    /// The base tone, then this moment's shift.
    static func instructions(base: String, shift: String?) -> String {
        guard let shift, !shift.isEmpty else { return base }
        return base + " Right now: " + shift + "."
    }

    /// A keep-mode result that grew is one the model added to; the original
    /// words are said instead.
    static func kept(_ said: String, original: String) -> String {
        said.isEmpty || said.count > original.count * 3 / 2 + 20 ? original : said
    }

    /// Reads the model's JSON. A model that answered in plain text still
    /// gives the words, with no tone.
    static func parseSpoken(_ raw: String) -> (say: String, tone: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        }
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let say = object["say"] as? String {
            let tone = (object["tone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (say, tone?.isEmpty == false ? tone : nil)
        }
        return (text, nil)
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

    static let explainPrompt = """
        A coding assistant is about to run a tool. Say out loud, in one short sentence, \
        what it is doing and why, to the developer it works with.

        - First person, present continuous: "I'm checking the log to see why it crashed."
        - At most 16 words. Plain, casual words, like a colleague.
        - Say the purpose when the context gives it. Never invent one.
        - No code, no paths, no flags, no quotes. Name a file by its name only.

        Output only the sentence.
        """

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

    /// The tool call, and what Claude wrote just before it, for `explainPrompt`.
    static func explainInput(tool: String, input: [String: Any], context: String?) -> String {
        var lines = ["Tool: \(tool)"]
        for key in ["description", "command", "file_path", "pattern", "query", "url"] {
            guard var value = input[key] as? String, !value.isEmpty else { continue }
            if key == "file_path" { value = basename(value) }
            lines.append("\(key): \(redacted(String(value.prefix(600))))")
        }
        if let context, !context.isEmpty {
            lines.append("What the assistant just wrote: \(clean(context).suffix(500))")
        }
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
    }

    /// Reads the tail of a session's `.jsonl` and returns the last turn.
    static func lastTurn(transcript url: URL, tailBytes: Int = 512 * 1024) -> TurnEnd? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return lastTurn(lines: text.split(separator: "\n").map(String.init))
    }

    static func lastTurn(lines: [String]) -> TurnEnd? {
        var entries: [[String: Any]] = []
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if isPrompt(entry) { break }
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
        return TurnEnd(answer: answer.joined(separator: "\n\n"), recap: recap, ask: ask, latestText: latest)
    }

    /// A line the person typed, as opposed to a tool result or a reminder the
    /// harness slipped in.
    private static func isPrompt(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return !blocks.contains { $0["type"] as? String == "tool_result" }
            && blocks.contains { $0["type"] as? String == "text" }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
