import Foundation

/// What Codex's hook events and rollout file sound like. The text rules and
/// the turn shape are `ClaudeSpeakable`'s.
enum CodexSpeakable {

    typealias Line = ClaudeSpeakable.Line

    // MARK: - Hook event → progress line

    /// Codex's `Bash` sends only the command and `apply_patch` only the patch,
    /// so the line comes from what the command is and which files the patch
    /// names. The command itself is never said.
    static func progress(tool: String, input: [String: Any]) -> Line? {
        let command = input["command"] as? String ?? ""
        switch tool {
        case "Bash":
            return commandLine(command)
        case "apply_patch":
            let (verb, files) = patch(command)
            return Line(text: "I'm \(ClaudeSpeakable.gerund(verb)) \(files)", kind: .edit)
        case "spawn_agent":
            return ClaudeSpeakable.progress(tool: "Agent", input: [:])
        case "request_user_input":
            return ClaudeSpeakable.progress(tool: "AskUserQuestion", input: input)
        default:
            return ClaudeSpeakable.progress(tool: tool, input: input)
        }
    }

    /// The line for a `PermissionRequest`: Codex waits for an approval.
    static func waiting(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return "I need your OK to run a command."
        case "apply_patch":
            let (verb, files) = patch(input["command"] as? String ?? "")
            return "I need your OK to \(verb) \(files)."
        default:
            return "I need your OK to go on."
        }
    }

    private static let reading: Set<String> = [
        "rg", "grep", "cat", "sed", "head", "tail", "ls", "find", "fd", "wc", "nl", "awk", "tree", "jq", "less",
    ]
    private static let testing: Set<String> = ["pytest", "jest", "vitest"]
    private static let building: Set<String> = ["make", "xcodebuild", "ninja", "cmake"]
    private static let wrappers: Set<String> = ["sudo", "env", "time", "nice", "command", "exec"]

    /// "cd proj && FOO=1 swift test" → "I'm running the tests".
    static func commandLine(_ command: String) -> Line {
        let words = mainCommand(command)
        let program = ClaudeSpeakable.basename(words.first ?? "")
        let rest = words.dropFirst()
        if reading.contains(program) {
            return Line(text: "I'm looking through the code", kind: .read)
        }
        if program == "git" {
            switch rest.first {
            case "diff", "status", "log", "show", "blame":
                return Line(text: "I'm looking at the changes", kind: .read)
            case "commit": return Line(text: "I'm committing", kind: .command)
            case "push": return Line(text: "I'm pushing", kind: .command)
            default: return Line(text: "I'm running git", kind: .command)
            }
        }
        // "swift test", "npm run build", "python -m pytest".
        let task = testing.contains(program) ? program : rest.first { !$0.hasPrefix("-") && $0 != "run" }
        if let task, task == "test" || testing.contains(task) {
            return Line(text: "I'm running the tests", kind: .command)
        }
        if building.contains(program) || task == "build" {
            return Line(text: "I'm building", kind: .command)
        }
        return Line(text: "I'm running a command", kind: .command)
    }

    /// The words of the first part of a shell line that does the work: past
    /// `cd`, variable settings and wrappers like `sudo` or `timeout 60`.
    private static func mainCommand(_ command: String) -> [String] {
        let parts = command.components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
        for part in parts {
            var words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first,
                  wrappers.contains(first) || first.contains("=") || first == "timeout" || Double(first) != nil {
                words.removeFirst()
            }
            guard let first = words.first, !["cd", "export", "source", "set"].contains(first) else { continue }
            return words
        }
        return []
    }

    /// The verb and the files of an `apply_patch` body, from its
    /// `*** Update File:`, `*** Add File:` and `*** Delete File:` headers.
    private static func patch(_ text: String) -> (verb: String, files: String) {
        let headers = [("*** Update File: ", "edit"), ("*** Add File: ", "write"), ("*** Delete File: ", "delete")]
        var changes: [(verb: String, file: String)] = []
        for line in text.split(separator: "\n") {
            guard let (header, verb) = headers.first(where: { line.hasPrefix($0.0) }) else { continue }
            let path = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            changes.append((verb, ClaudeSpeakable.basename(path)))
        }
        let verbs = Set(changes.map(\.verb))
        let verb = verbs.count == 1 ? verbs.first ?? "edit" : "edit"
        let files = switch changes.count {
        case 0: "a file"
        case 1: changes[0].file
        case 2: changes[0].file + " and " + changes[1].file
        default: "\(changes.count) files"
        }
        return (verb, files)
    }

    // MARK: - Rollout → the turn that just ended

    /// A rollout line that matters for speech. Newer rollouts write
    /// `item_completed` items, older ones `user_message` and `agent_message`.
    /// `response_item` user messages are skipped: they also hold the context
    /// Codex injects.
    private enum Item {
        case prompt(String)
        case message(String, commentary: Bool)
        case finished(String)
    }

    private static func item(_ line: String) -> Item? {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              entry["type"] as? String == "event_msg",
              let payload = entry["payload"] as? [String: Any] else { return nil }
        switch payload["type"] as? String {
        case "user_message":
            return (payload["message"] as? String).map(Item.prompt)
        case "agent_message":
            return (payload["message"] as? String)?.nilIfEmpty
                .map { .message($0, commentary: payload["phase"] as? String == "commentary") }
        case "task_complete":
            return (payload["last_agent_message"] as? String)?.nilIfEmpty.map(Item.finished)
        case "item_completed":
            guard let item = payload["item"] as? [String: Any] else { return nil }
            let text = (item["content"] as? [[String: Any]] ?? [])
                .compactMap { ($0["type"] as? String)?.lowercased() == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            switch item["type"] as? String {
            case "UserMessage": return .prompt(text)
            case "AgentMessage": return text.nilIfEmpty.map { .message($0, commentary: item["phase"] as? String == "commentary") }
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Reads the tail of a rollout `.jsonl` and returns the last turn.
    static func lastTurn(transcript url: URL, tailBytes: Int = 512 * 1024) -> ClaudeSpeakable.TurnEnd? {
        ClaudeSpeakable.tail(of: url, bytes: tailBytes).flatMap(lastTurn(lines:))
    }

    /// The answer is the final message, never the commentary between tool
    /// calls; `latestText` is the newest message of either kind.
    static func lastTurn(lines: [String]) -> ClaudeSpeakable.TurnEnd? {
        let items = lines.compactMap(item)
        let starts = items.indices.filter {
            if case .prompt = items[$0] { true } else { false }
        }
        let start = starts.last ?? items.startIndex
        guard var ended = turn(items[start...]) else { return nil }
        if start > items.startIndex, let before = turn(items[(starts.dropLast().last ?? items.startIndex)..<start]) {
            ended.earlier = ClaudeSpeakable.Earlier(prompt: before.prompt, answer: before.answer, recap: nil)
        }
        return ended
    }

    private static func turn(_ items: ArraySlice<Item>) -> ClaudeSpeakable.TurnEnd? {
        var prompt: String?
        var answer: String?
        var finished: String?
        var latest: String?
        for item in items {
            switch item {
            case .prompt(let text): prompt = text
            case .message(let text, let commentary):
                latest = text
                if !commentary { answer = text }
            case .finished(let text): finished = text
            }
        }
        guard prompt != nil || latest != nil || finished != nil else { return nil }
        return ClaudeSpeakable.TurnEnd(answer: answer ?? finished ?? "", latestText: latest, prompt: prompt)
    }

    static func latestSummary(transcript url: URL, tailBytes: Int = 512 * 1024) -> String? {
        ClaudeSpeakable.tail(of: url, bytes: tailBytes).flatMap(latestSummary(lines:))
    }

    /// The newest final answer across turns, else the newest commentary.
    static func latestSummary(lines: [String]) -> String? {
        var commentary: String?
        for item in lines.compactMap(item).reversed() {
            switch item {
            case .finished(let text), .message(let text, false): return String(text.prefix(600))
            case .message(let text, true): commentary = commentary ?? text
            case .prompt: break
            }
        }
        return commentary.map { String($0.prefix(600)) }
    }
}
