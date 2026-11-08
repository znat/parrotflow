import FluidAudio
import Foundation
import Yams

/// The terminal side of `ClaudeVoice`.
///
///   --speak-event               what the hooks run; stdin → the app's socket
///   --install-claude-hooks      into `voice.agents.claude`'s folders; `--agent codex`: Codex's
///   --uninstall-claude-hooks
///   --claude-voice-test <cases> score the text rules, no audio
///   --claude-spoken <file>      what the last turn of a transcript would say
///   --claude-say "<text>"       say it through PocketTTS or the remote voice
enum ClaudeHooksCommand {

    static let marker = "--speak-event"

    // MARK: - The hook

    /// Always exits 0: a hook that exits 2 blocks the tool call it fired on.
    static func speakEvent() -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return 0 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = ClaudeVoice.socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return 0 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Not running: nothing to say, and nothing to report to Claude.
        guard connected == 0 else { return 0 }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let wrote = write(fd, base + sent, raw.count - sent)
                guard wrote > 0 else { break }
                sent += wrote
            }
        }
        return 0
    }

    // MARK: - Install

    /// `--install-claude-hooks` and `--uninstall-claude-hooks`.
    static func hooks(_ arguments: [String], config: Config?) -> Int32 {
        let named = arguments.firstIndex(of: "--agent").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : "" }
        let agent = named == nil ? .claude : named.flatMap(CodingAgent.init(rawValue:))
        guard let agent, !agent.hookEvents.isEmpty else {
            print("✗ --agent takes claude or codex")
            return 2
        }
        let folders = folders(arguments, agent: agent, config: config)
        return arguments.contains("--install-claude-hooks")
            ? run(true, folders: folders, agent: agent, flag: "--install-claude-hooks")
            : run(false, folders: folders, agent: agent, flag: "--uninstall-claude-hooks")
    }

    static func folders(_ arguments: [String], agent: CodingAgent, config: Config?) -> [URL] {
        var given: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--folder", arguments.indices.contains(index + 1) {
                given.append(arguments[index + 1])
                index += 1
            }
            index += 1
        }
        if !given.isEmpty {
            return given.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        }
        let settings = config?.voice ?? Config.Voice()
        return settings.folders(of: agent) ?? Config.Voice.urls(agent.defaultFolders)
    }

    /// Names our hook in `settings.json`, for uninstall. Hooks written by older
    /// builds carry `marker` instead.
    static let tag = "parrotflow-speak-event"

    /// One app variant's hook. The dev and release apps each listen on their
    /// own socket, and each owns only the entries that name it: both are often
    /// installed at once.
    struct Hook {
        var socket: String
        /// `/ParrotFlowDev.app/`: hooks from older builds ran that binary with `marker`.
        var app: String
        var agent = CodingAgent.claude

        /// `nc` to the app's socket, not the app binary. The binary in a hook
        /// blocked Claude once that build was uninstalled, and a build that does
        /// not know `--speak-event` starts a second menu bar app on every tool
        /// call. `nc` exits in about 10 ms either way, and `exit 0` keeps a missing
        /// app silent. `$PPID` is the agent's process, which `SpeakingFrame` walks
        /// up from to find the window to frame.
        var command: String {
            "[ -S '\(socket)' ] && { echo \"pid=$PPID\"; echo agent=\(agent.rawValue); cat; }"
                + " | /usr/bin/nc -U -w 1 '\(socket)' >/dev/null 2>&1;"
                + " exit 0 # \(tag)"
        }

        func owns(_ command: String) -> Bool {
            command.contains(tag) ? command.contains("'\(socket)'") : command.contains(marker) && command.contains(app)
        }

        /// Codex trusts a hook by a hash of this entry, so a change here asks
        /// every Codex user to approve it again.
        func entry(matcher: String?) -> [String: Any] {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 2]]]
            entry["matcher"] = matcher
            return entry
        }

        /// nil for a `.build` binary: it has no bundle id, so its socket path
        /// would be the release app's.
        static var current: Hook? {
            guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                  let bundle = path.range(of: ".app/Contents/MacOS/") else { return nil }
            let name = (String(path[..<bundle.lowerBound]) as NSString).lastPathComponent
            return Hook(socket: ClaudeVoice.socketURL.path, app: "/\(name).app/")
        }
    }

    enum Change: Equatable {
        case unchanged, written, failed(String)
    }

    static let codexTrust = "approve them once in Codex, under /hooks or Settings > Hooks"

    private static func run(_ on: Bool, folders: [URL], agent: CodingAgent, flag: String) -> Int32 {
        guard var hook = Hook.current else {
            print("✗ Run this from the installed app, not from .build:")
            print("  /Applications/\(AppVariant.isDev ? "ParrotFlowDev" : "ParrotFlow").app/Contents/MacOS/ParrotFlow \(flag)")
            return 1
        }
        hook.agent = agent
        var failed = false
        for (folder, change) in reconcile(enabled: on, folders: folders, hook: hook) {
            if case .failed(let why) = change {
                print("✗ \(why)")
                failed = true
            } else if !isFolder(folder) {
                print("· \(shown(folder)): no such folder, so nothing to do")
            } else {
                print("✓ \(shown(folder))/\(agent.hooksFile)")
            }
        }
        if on, !failed {
            print(agent == .codex
                ? "  Codex runs new hooks only once you \(codexTrust)."
                : "  Claude Code reads hooks at the start of a session, so restart open sessions.")
        }
        return failed ? 1 : 0
    }

    /// In every folder when on, out when off. A file that already matches is
    /// not written.
    static func reconcile(enabled: Bool, folders: [URL], hook: Hook) -> [(folder: URL, change: Change)] {
        folders.map { folder in
            (folder, edit(folder: folder, agent: hook.agent) { hooks in
                enabled ? installing(hooks, hook) : removing(hooks, hook)
            })
        }
    }

    /// Each agent's hooks, whether they belong in, and where. An agent that is
    /// off has them taken out of its default folders.
    static func targets(_ settings: Config.Voice, hook: Hook) -> [(hook: Hook, enabled: Bool, folders: [URL])] {
        CodingAgent.hooked.map { agent in
            var hook = hook
            hook.agent = agent
            let folders = settings.folders(of: agent)
            return (hook, settings.enabled && folders != nil,
                    folders ?? Config.Voice.urls(agent.defaultFolders))
        }
    }

    static func shown(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// An event that already holds exactly our entry keeps its place. A new
    /// one goes last: Codex keys its trust by the entry's index.
    private static func installing(_ hooks: [String: Any], _ hook: Hook) -> [String: Any] {
        var hooks = hooks
        for (event, matcher) in hook.agent.hookEvents {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let wanted = hook.entry(matcher: matcher)
            let others = entries.filter { !NSDictionary(dictionary: $0).isEqual(to: wanted) }
            let kept = withoutOurs(entries, hook)
            if entries.count - others.count == 1, NSArray(array: kept).isEqual(to: others) { continue }
            hooks[event] = kept + [wanted]
        }
        return hooks
    }

    private static func removing(_ hooks: [String: Any], _ hook: Hook) -> [String: Any] {
        var hooks = hooks
        for (event, _) in hook.agent.hookEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = withoutOurs(entries, hook)
            if NSArray(array: kept).isEqual(to: entries) { continue }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        return hooks
    }

    private static func withoutOurs(_ entries: [[String: Any]], _ hook: Hook) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let all = entry["hooks"] as? [[String: Any]] else { return entry }
            let kept = all.filter { !hook.owns($0["command"] as? String ?? "") }
            if kept.count == all.count { return entry }
            if kept.isEmpty { return nil }
            var entry = entry
            entry["hooks"] = kept
            return entry
        }
    }

    /// Reads the agent's hooks file, changes `hooks`, writes it back when they
    /// changed. Keeps the first copy it ever changed as `<file>.parrotflow-backup`.
    private static func edit(folder: URL, agent: CodingAgent, _ change: ([String: Any]) -> [String: Any]) -> Change {
        let place = "\(shown(folder))/\(agent.hooksFile)"
        let file = folder.appendingPathComponent(agent.hooksFile)
        guard isFolder(folder) else {
            // Nothing to take out of a folder that is not there. No Codex folder means no Codex.
            return change([:]).isEmpty || agent == .codex ? .unchanged : .failed("\(shown(folder)): no such folder")
        }
        var original: Data?
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                original = try Data(contentsOf: file)
            } catch {
                return .failed("\(place): \(error.localizedDescription)")
            }
        }
        var settings: [String: Any] = [:]
        if let original, !original.isEmpty {
            guard let read = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                return .failed("\(place) is not a JSON object — left alone")
            }
            settings = read
        }
        let before = settings["hooks"] as? [String: Any] ?? [:]
        let after = change(before)
        guard !NSDictionary(dictionary: before).isEqual(to: after) else { return .unchanged }
        settings["hooks"] = after.isEmpty ? nil : after
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try writeSettings(data + Data("\n".utf8), to: file, original: original)
        } catch {
            return .failed("\(place): \(error.localizedDescription)")
        }
        return .written
    }

    /// A settings file can hold keys: the new file and the backup keep its
    /// mode, 0600 when it is new. Through a symlink, so a linked file stays linked.
    private static func writeSettings(_ data: Data, to file: URL, original: Data?) throws {
        let target = file.resolvingSymlinksInPath()
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
            as? NSNumber)?.uint16Value ?? 0o600
        let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".parrotflow-backup")
        if let original, !original.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
            try ConfigMigration.create(backup, holding: original, mode: mode)
        }
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).parrotflow-\(getpid())")
        unlink(temporary.path)
        try ConfigMigration.create(temporary, holding: data, mode: mode)
        guard rename(temporary.path, target.path) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary.path)
            throw failure
        }
    }

    // MARK: - Checks

    struct Cases: Decodable {
        struct Clean: Decodable { var name: String; var input: String; var want: String }
        struct Progress: Decodable {
            var name: String; var tool: String; var input: [String: String]?; var want: String?; var agent: String?
        }
        struct CodexTurn: Decodable {
            var name: String; var lines: [String]; var prompt: String?; var answer: String; var latest: String?
            var earlier: String?
        }
        struct Turn: Decodable {
            var name: String; var lines: [String]; var answer: String; var recap: String?
            var earlier: String?
        }
        struct Parse: Decodable {
            var name: String; var raw: String; var say: String; var tone: String?; var opener: String?; var task: String?
        }
        struct SessionName: Decodable {
            var name: String; var project: String; var label: String?; var prompt: String?; var want: String?
        }
        var clean: [Clean] = []
        var progress: [Progress] = []
        var turns: [Turn] = []
        var parse: [Parse] = []
        var capped: [Clean] = []
        var redacted: [Clean] = []
        struct Naming: Decodable {
            var name: String; var otherSpokeLast: Bool; var quietFor: Double; var inFront: Bool; var named: Bool
            enum CodingKeys: String, CodingKey {
                case name, named
                case otherSpokeLast = "other_spoke_last"
                case quietFor = "quiet_for"
                case inFront = "in_front"
            }
        }
        var naming: [Naming] = []
        struct Grounding: Decodable { var name: String; var said: String; var source: String; var kept: Bool }
        var grounded: [Grounding] = []
        var speakable: [Clean] = []
        var spoken: [Clean] = []
        struct Summary: Decodable { var name: String; var lines: [String]; var want: String?; var agent: String? }
        var summary: [Summary] = []
        var titles: [Summary] = []
        var waiting: [Progress] = []
        var codexTurns: [CodexTurn] = []
        var sessionNames: [SessionName] = []

        enum CodingKeys: String, CodingKey {
            case clean, progress, turns, parse, capped, redacted, naming, grounded, speakable, spoken, summary, waiting, titles
            case codexTurns = "codex_turns"
            case sessionNames = "session_names"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clean = try c.decodeIfPresent([Clean].self, forKey: .clean) ?? []
            progress = try c.decodeIfPresent([Progress].self, forKey: .progress) ?? []
            turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
            parse = try c.decodeIfPresent([Parse].self, forKey: .parse) ?? []
            capped = try c.decodeIfPresent([Clean].self, forKey: .capped) ?? []
            redacted = try c.decodeIfPresent([Clean].self, forKey: .redacted) ?? []
            naming = try c.decodeIfPresent([Naming].self, forKey: .naming) ?? []
            grounded = try c.decodeIfPresent([Grounding].self, forKey: .grounded) ?? []
            speakable = try c.decodeIfPresent([Clean].self, forKey: .speakable) ?? []
            spoken = try c.decodeIfPresent([Clean].self, forKey: .spoken) ?? []
            summary = try c.decodeIfPresent([Summary].self, forKey: .summary) ?? []
            titles = try c.decodeIfPresent([Summary].self, forKey: .titles) ?? []
            waiting = try c.decodeIfPresent([Progress].self, forKey: .waiting) ?? []
            codexTurns = try c.decodeIfPresent([CodexTurn].self, forKey: .codexTurns) ?? []
            sessionNames = try c.decodeIfPresent([SessionName].self, forKey: .sessionNames) ?? []
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
        func agent(_ name: String?) -> CodingAgent { name.flatMap(CodingAgent.init(rawValue:)) ?? .claude }
        for item in cases.progress {
            let line = agent(item.agent).progress(tool: item.tool, input: item.input ?? [:])
            check(item.name, got: line?.text, want: item.want)
        }
        for item in cases.waiting {
            check(item.name, got: CodexSpeakable.waiting(tool: item.tool, input: item.input ?? [:]), want: item.want)
        }
        for item in cases.codexTurns {
            let ended = CodexSpeakable.lastTurn(lines: item.lines)
            check(item.name, got: ended?.answer, want: item.answer)
            check(item.name + " (prompt)", got: ended?.prompt, want: item.prompt)
            check(item.name + " (latest)", got: ended?.latestText, want: item.latest)
            check(item.name + " (earlier)", got: ended?.earlier?.answer, want: item.earlier)
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
            check(item.name + " (task)", got: parsed.task, want: item.task)
        }
        for item in cases.sessionNames {
            let task = item.label ?? ClaudeSpeakable.taskWords(item.prompt, skipping: item.project)
            check(item.name, got: ClaudeSpeakable.sessionName(project: item.project, task: task), want: item.want)
        }
        for item in cases.capped {
            check(item.name, got: ClaudeSpeakable.capped(item.input), want: item.want)
        }
        for item in cases.redacted {
            check(item.name, got: ClaudeSpeakable.redacted(item.input), want: item.want)
        }
        for item in cases.naming {
            let said = ClaudeVoice.names(
                otherSpokeLast: item.otherSpokeLast, quietFor: item.quietFor, inFront: item.inFront
            )
            check(item.name, got: said ? "named" : "not named", want: item.named ? "named" : "not named")
        }
        for item in cases.summary {
            let got = agent(item.agent) == .codex
                ? CodexSpeakable.latestSummary(lines: item.lines) : ClaudeSpeakable.latestSummary(lines: item.lines)
            check(item.name, got: got, want: item.want)
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-voice-titles-\(getpid())")
        let session = home.appendingPathComponent(
            "sessions/2026/11/08/rollout-2026-11-08T10-00-00-0199a3b2-7c4d-7e8f-9a0b-1c2d3e4f5a6b.jsonl"
        )
        try? FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        for item in cases.titles {
            let codex = agent(item.agent) == .codex
            let file = codex ? home.appendingPathComponent("session_index.jsonl") : session
            try? Data((item.lines.joined(separator: "\n") + "\n").utf8).write(to: file)
            check(item.name, got: agent(item.agent).title(transcript: session), want: item.want)
            try? FileManager.default.removeItem(at: file)
        }
        let early = [#"{"type":"ai-title","aiTitle":"Early title"}"#, String(repeating: "x", count: 600 * 1024), "{}"]
        try? Data(early.joined(separator: "\n").utf8).write(to: session)
        check("a title far from the end of the file is found", got: CodingAgent.claude.title(transcript: session),
              want: "Early title")
        let index = #"{"id":"0199a3b2-7c4d-7e8f-9a0b-1c2d3e4f5a6b","thread_name":"Reverted thread"}"#
        try? Data(index.utf8).write(to: home.appendingPathComponent("session_index.jsonl"))
        let reverted = session.deletingLastPathComponent().appendingPathComponent(
            "rollout-2026-11-08T10-00-00-0199a3b2-7c4d-7e8f-9a0b-1c2d3e4f5a6b_0199a3b2-9999-7e8f-9a0b-1c2d3e4f5a6b.jsonl"
        )
        check("a reverted Codex rollout is named by its thread id", got: CodingAgent.codex.title(transcript: reverted),
              want: "Reverted thread")
        try? FileManager.default.removeItem(at: home)
        check("the reminder gets the session's task, without its secrets",
              got: ClaudeSpeakable.reminderInput(request: "how big is it?", latest: "Measured what the gate adds.",
                                                 task: "Vocab gate with token=abc123"),
              want: "Language: English\nTask: Vocab gate with token=<redacted>\nRequest: how big is it?\n"
                + "Latest: Measured what the gate adds.")
        check("an empty task is no Task line",
              got: ClaudeSpeakable.reminderInput(request: "go on", latest: nil, task: ""),
              want: "Language: English\nRequest: go on.")
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
        let count = ClaudeVoice.introductions.count
        let repeats = (0..<count).flatMap { last in (0..<50).map { (last, $0) } }
            .filter { ClaudeVoice.introductionIndex(after: $0.0, seed: $0.1) == $0.0 }
        check("introductions never repeat back to back", got: "\(repeats.count)", want: "0")
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
        check("a French introduction", got: ClaudeVoice.introduction("parrotflow", 2, language: "fr"),
              want: "Ici parrotflow : ")
        check("a language with no introductions uses English", got: ClaudeVoice.introduction("parrotflow", 2, language: "de"),
              want: "parrotflow here: ")
        check("a capital after a period", got: ClaudeSpeakable.capped("A new term. my examples were wrong."),
              want: "A new term. My examples were wrong.")
        check("the reply and recap lose their secrets",
              got: ClaudeSpeakable.rewriteInput(request: nil, reply: "Set API_KEY=sk-abc123", recap: "Bearer xyz789"),
              want: "Language: English\n\nReply: Set API_KEY=<redacted>\n\nRecap: Bearer <redacted>")
        check("the latest summary loses its secrets",
              got: ClaudeSpeakable.reminderInput(request: "go on", latest: "I used token=abc123 there"),
              want: "Language: English\nRequest: go on.\nLatest: I used token=<redacted> there.")
        check("what the assistant wrote loses its secrets",
              got: ClaudeSpeakable.explainInput(tool: "Bash", input: [:], context: "Use password: hunter2 now"),
              want: "Language: English\nTool: Bash\nWhat the assistant just wrote: Use password: <redacted> now.")
        check("the opening and the lines already said",
              got: ClaudeSpeakable.explainInput(tool: "Bash", input: [:], context: nil, opening: 3,
                                                said: ["Now the tests.", "Counting proposals."]),
              want: "Language: English\nTool: Bash\nOpening: 3\nAlready said:\n- Now the tests.\n- Counting proposals.")
        check("a prompt's numbered openings", got: String(VoicePrompt.openings(in: "- a\n  1. Now\n  2. Next\n10. Ten\n3 no")),
              want: "3")
        check("an opening is never the last one twice", got: VoicePrompt.opening(count: 2, after: 1).map(String.init), want: "2")
        check("no openings, no opening", got: VoicePrompt.opening(count: 0, after: nil).map(String.init), want: nil)
        let cut = ClaudeSpeakable.explainInput(
            tool: "Bash", input: [:], context: "Use token=hunter2 " + String(repeating: "ok ", count: 164)
        )
        let fallback = ClaudeSpeakable.truncated(ClaudeSpeakable.clean(
            "Done. I set `OPENROUTER_API_KEY=sk-or-v1-abcdef1234567890` in your shell."
        ))
        check("a key in a reply said plain is not said", got: ClaudeSpeakable.spokenRedacted(fallback),
              want: "Done. I set OPENROUTER_API_KEY=redacted in your shell.")
        check("a password after a colon is not said", got: ClaudeSpeakable.spokenRedacted("Use password: hunter2 now."),
              want: "Use password: redacted now.")
        check("a Bearer header is said, its value is not",
              got: ClaudeSpeakable.spokenRedacted("Add a Bearer token header with Bearer abc123xyz."),
              want: "Add a Bearer token header with Bearer redacted.")
        check("a Bearer value with a sign, a colon or 8 letters is not said",
              got: ClaudeSpeakable.spokenRedacted("Bearer abc%2Fdef:ghi, Bearer x-y and Bearer abcdefghij."),
              want: "Bearer redacted, Bearer redacted and Bearer redacted.")
        check("the bearer of bad news is said as it is",
              got: ClaudeSpeakable.spokenRedacted("He was the bearer of bad news, so Bearer tokens wait."),
              want: "He was the bearer of bad news, so Bearer tokens wait.")
        check("prose about a token is said as it is",
              got: ClaudeSpeakable.spokenRedacted("The token expired, so I refreshed the skyscrapers page."),
              want: "The token expired, so I refreshed the skyscrapers page.")
        let spoken: [(String, String, String)] = [
            ("a URL loses its query", "Open https://example.com/cb?token=abc123&key=xyz now.",
             "Open https://example.com/cb now."),
            ("a short password after a colon is not said", "Set password: x9 there.", "Set password: redacted there."),
            ("an api_key after = is not said", "Use api_key=abc123def.", "Use api_key=redacted."),
            ("an exported token is not said", "Run export FOO_TOKEN=ghp_abcdefgh12345678 first.",
             "Run export FOO_TOKEN=redacted first."),
            ("a password after a space is not said", "Type password hunter2 to log in.",
             "Type password redacted to log in."),
            ("a password reset is said as it is", "Your password reset link is on its way.",
             "Your password reset link is on its way."),
            ("a secret in prose is said as it is", "The secret is to test first.", "The secret is to test first."),
            ("an accented word after a token is said", "Le token était expiré.", "Le token était expiré."),
        ]
        for (name, input, want) in spoken {
            check(name, got: ClaudeSpeakable.spokenRedacted(input), want: want)
        }
        check("a secret is redacted before the cut", got: cut.contains("unter2") ? "leaks" : "redacted",
              want: "redacted")
        let tail = FileManager.default.temporaryDirectory.appendingPathComponent("claude-voice-tail-\(getpid()).jsonl")
        let transcript = "é\n" + #"{"type":"user","message":{"role":"user","content":"go"}}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"# + "\n"
        try? Data(transcript.utf8).write(to: tail)
        check("a tail that starts inside a character still reads",
              got: ClaudeSpeakable.lastTurn(transcript: tail, tailBytes: transcript.utf8.count - 1)?.answer,
              want: "Done.")
        try? FileManager.default.removeItem(at: tail)
        let rollout = tail.deletingPathExtension().appendingPathExtension("rollout.jsonl")
        let rolloutLines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"an old prompt cut by the tail"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"rename foo"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Renamed it.","phase":"final_answer"}}"#,
        ]
        let rolloutText = rolloutLines.joined(separator: "\n") + "\n"
        try? Data(rolloutText.utf8).write(to: rollout)
        let codexTurn = CodingAgent.codex.lastTurn(transcript: rollout,
                                                   tailBytes: rolloutText.utf8.count - rolloutLines[0].utf8.count + 5)
        check("a Codex rollout tail reads its last turn, the cut line is skipped",
              got: [codexTurn?.prompt, codexTurn?.answer, codexTurn?.earlier == nil ? "no earlier" : "earlier"]
                .map { $0 ?? "-" }.joined(separator: " | "),
              want: "rename foo | Renamed it. | no earlier")
        try? FileManager.default.removeItem(at: rollout)
        check("a compressed Codex rollout is not read",
              got: ClaudeVoice.transcript(["transcript_path": "/s/rollout-1.jsonl.zst"])?.path ?? "not read", want: "not read")
        check("a plain Codex rollout is read",
              got: ClaudeVoice.transcript(["transcript_path": "/s/rollout-1.jsonl"])?.path ?? "not read",
              want: "/s/rollout-1.jsonl")
        let pane = CGRect(x: 100, y: 200, width: 800, height: 600)
        check("a pane 3 points off is the same place",
              got: SpeakingFrame.close(pane, pane.offsetBy(dx: 3, dy: -3)) ? "same" : "other", want: "same")
        check("a pane 4 points wider is another place",
              got: SpeakingFrame.close(pane, pane.insetBy(dx: -2, dy: 0)) ? "same" : "other", want: "other")
        // A pane at y 200 to 800 in AppKit is y 200 to 800 from the top of a 1000-point main screen.
        let terminal: pid_t = 10, other: pid_t = 20
        let ownWindow = (pid: terminal, bounds: CGRect(x: 50, y: 150, width: 900, height: 700))
        func sight(_ windows: [(pid: pid_t, bounds: CGRect)]) -> String {
            SpeakingFrame.covered(pane, host: terminal, top: 1000, windows: windows) ? "hidden" : "shown"
        }
        check("the glow shows on its own window in front", got: sight([ownWindow]), want: "shown")
        check("the glow hides behind another app", got: sight([(other, pane.insetBy(dx: 200, dy: 200)), ownWindow]),
              want: "hidden")
        check("the glow hides behind another window of the same terminal",
              got: sight([(terminal, pane.insetBy(dx: 200, dy: 200)), ownWindow]), want: "hidden")
        check("the glow hides when its window is off screen", got: sight([(other, CGRect(x: 0, y: 0, width: 40, height: 40))]),
              want: "hidden")
        typealias Ancestor = SpeakingFrame.Ancestor
        let shell = Ancestor(pid: 3, arguments: ["-zsh"])
        let iterm = Ancestor(pid: 9, bundle: "com.googlecode.iterm2", regular: true)
        let tui = Ancestor(pid: 5, arguments: ["/opt/homebrew/bin/codex", "--yolo"])
        let desktop = Ancestor(pid: 7, bundle: "com.openai.codex", regular: true)
        func host(_ chain: [Ancestor]) -> String {
            switch SpeakingFrame.codexHost(chain) {
            case .app(let pid): "app \(pid)"
            case .byTitle: "title"
            case .none: "none"
            }
        }
        let server = Ancestor(pid: 4, arguments: ["codex", "app-server", "--analytics-default-enabled"])
        let daemon = Ancestor(pid: 4, arguments: ["/usr/local/bin/codex", "app-server", "--managed-daemon"])
        check("codex in the desktop app: the app", got: host([server, Ancestor(pid: 6, arguments: ["ChatGPT Helper"]), desktop]),
              want: "app 7")
        check("codex in a terminal, no daemon: the terminal", got: host([tui, shell, iterm]), want: "app 9")
        check("codex behind the daemon a first session started: by title",
              got: host([daemon, tui, shell, iterm]), want: "title")
        check("codex behind an older daemon with no flag, under a session: by title",
              got: host([server, tui, shell, iterm]), want: "title")
        check("codex behind a daemon left to launchd: by title", got: host([daemon]), want: "title")
        check("codex behind an older daemon left to launchd: by title", got: host([server]), want: "title")
        check("codex behind the daemon the desktop app started: by title", got: host([daemon, desktop]), want: "title")
        check("codex in the VS Code extension: VS Code",
              got: host([server, Ancestor(pid: 6, arguments: ["Code Helper (Plugin)"]),
                         Ancestor(pid: 8, bundle: "com.microsoft.VSCode", regular: true)]), want: "app 8")
        check("the CLI bundled in ChatGPT.app is not a host",
              got: host([Ancestor(pid: 5, bundle: "com.openai.codex.cli", regular: true, arguments: ["codex"]), shell, iterm]),
              want: "app 9")
        check("codex under tmux: no host", got: host([tui, shell, Ancestor(pid: 2, arguments: ["tmux"])]), want: "none")
        var procargs: [UInt8] = [3, 0, 0, 0]
        for field in ["/x/codex", "", "", "codex", "app-server", "--managed-daemon", "HOME=/u"] {
            procargs += Array(field.utf8) + [0]
        }
        check("process arguments stop before the environment",
              got: SpeakingFrame.arguments(procargs: procargs).joined(separator: " "),
              want: "codex app-server --managed-daemon")
        check("this process's own arguments are read",
              got: SpeakingFrame.ancestors(of: getpid()).first?.arguments.dropFirst().first ?? "-",
              want: "--claude-voice-test")
        let long = "a-rather-long-project-folder"
        let titles: [(String?, String, Bool)] = [
            ("⠋ Working · fix the glow · parrotflow", "parrotflow", true),
            ("PARROTFLOW", "parrotflow", true),
            ("codex · parrotflow-scratch", "parrotflow", false),
            ("rapid notes", "api", false),
            ("codex · a-rather-long-project...", long, true),
            ("codex · \(long)", long, false),
            ("parrotflow", "", false),
            (nil, "parrotflow", false),
        ]
        for (title, project, want) in titles {
            check("\"\(title ?? "no title")\" names \"\(project)\": \(want)",
                  got: "\(SpeakingFrame.names(title, project: project))", want: "\(want)")
        }
        let left = CGRect(x: 0, y: 0, width: 800, height: 600), right = CGRect(x: 820, y: 0, width: 800, height: 600)
        func picked(_ windows: [(title: String?, rect: CGRect?)], taken: [CGRect] = []) -> String {
            SpeakingFrame.pick(windows, project: "parrotflow", taken: taken).map { "\($0)" } ?? "none"
        }
        check("one window names the project: that one",
              got: picked([("zsh", left), ("codex · parrotflow", right)]), want: "1")
        check("two windows name the project: none", got: picked([("parrotflow", left), ("parrotflow", right)]), want: "none")
        check("no window names the project: none", got: picked([("zsh", left), ("notes", right)]), want: "none")
        check("two name it, another session holds one: the other",
              got: picked([("parrotflow", left), ("parrotflow", right)], taken: [left]), want: "1")
        check("the only one is held by another session: none",
              got: picked([("parrotflow", left), ("zsh", right)], taken: [left]), want: "none")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-hooks-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = folder.appendingPathComponent("settings.json")
        let backup = folder.appendingPathComponent("settings.json.parrotflow-backup")
        let release = Hook(socket: "/s/ParrotFlow/claude.sock", app: "/ParrotFlow.app/")
        let dev = Hook(socket: "/s/ParrotFlow Dev/claude.sock", app: "/ParrotFlowDev.app/")
        func hooks(_ on: Bool, _ hook: Hook, in place: URL? = nil) -> String {
            switch reconcile(enabled: on, folders: [place ?? folder], hook: hook).first?.change {
            case .written: "written"
            case .failed: "failed"
            default: "none"
            }
        }
        func contents(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func fileMode(_ url: URL) -> String {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)
                .map { String($0.intValue, radix: 8) } ?? "none"
        }
        func hookCount(_ hook: Hook, in file: URL? = nil) -> String {
            "\((contents(file ?? settings).components(separatedBy: "'\(hook.socket)'").count - 1) / 2)"
        }
        func seedSettings(_ json: String) {
            try? FileManager.default.removeItem(at: settings)
            try? FileManager.default.removeItem(at: backup)
            try? ConfigMigration.create(settings, holding: Data(json.utf8), mode: 0o600)
        }
        func parsed(_ text: String) -> NSDictionary? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary
        }
        check("hooks on: written into a new file", got: hooks(true, release), want: "written")
        check("hooks on: one per event", got: hookCount(release), want: "4")
        check("a new settings file is 0600", got: fileMode(settings), want: "600")
        check("hooks on again: no write", got: hooks(true, release), want: "none")
        check("the other variant installs beside it", got: hooks(true, dev), want: "written")
        check("both variants hold their own hooks", got: hookCount(release) + " " + hookCount(dev), want: "4 4")
        check("hooks off: removed", got: hooks(false, dev), want: "written")
        check("the other variant's hooks stay", got: hookCount(release) + " " + hookCount(dev), want: "4 0")
        check("hooks off again: no write", got: hooks(false, dev), want: "none")
        let foreign = #"{"env":{"API_KEY":"x"},"hooks":{"Stop":[{"hooks":[{"command":"say done","type":"command"}]},"#
            + #"{"matcher":"Bash","hooks":[]},{"matcher":"Edit"}]}}"#
        seedSettings(foreign)
        _ = hooks(true, release)
        check("a 0600 settings file stays 0600 after install", got: fileMode(settings), want: "600")
        check("its backup is the first copy, 0600 too",
              got: fileMode(backup) + " " + (contents(backup) == foreign ? "first" : "other"), want: "600 first")
        _ = hooks(false, release)
        check("a 0600 settings file stays 0600 after uninstall", got: fileMode(settings), want: "600")
        check("another tool's hooks and keys stay",
              got: parsed(contents(settings)) == parsed(foreign) ? "same" : contents(settings), want: "same")
        seedSettings(#"{"hooks":{"Stop":[{"hooks":["#
            + #"{"command":"/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --speak-event","type":"command"},"#
            + #"{"command":"/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --speak-event","type":"command"}]}]}}"#)
        _ = hooks(false, dev)
        check("an older dev hook goes, the older release one stays",
              got: ["ParrotFlowDev.app", "ParrotFlow.app"].filter(contents(settings).contains).joined(separator: " "),
              want: "ParrotFlow.app")
        seedSettings("{")
        check("broken JSON is left alone", got: hooks(true, release) + " " + contents(settings), want: "failed {")
        seedSettings(#"{"hooks":{"Stop":[{"hooks":[{"command":"[ -S '/s/ParrotFlow/claude.sock' ] && "#
            + #"{ echo \"pid=$PPID\"; cat; } | /usr/bin/nc -U -w 1 '/s/ParrotFlow/claude.sock' >/dev/null 2>&1; "#
            + #"exit 0 # parrotflow-speak-event","timeout":2,"type":"command"}]}]}}"#)
        check("a hook without agent= is upgraded", got: hooks(true, release), want: "written")
        check("the upgraded hooks send agent=claude, one per event",
              got: hookCount(release) + " " + "\(contents(settings).components(separatedBy: "echo agent=claude;").count - 1)",
              want: "4 4")
        check("an upgraded hook is not written again", got: hooks(true, release), want: "none")
        let codexFolder = folder.appendingPathComponent("codex")
        let codexFile = codexFolder.appendingPathComponent("hooks.json")
        let codexBackup = codexFolder.appendingPathComponent("hooks.json.parrotflow-backup")
        try? FileManager.default.createDirectory(at: codexFolder, withIntermediateDirectories: true)
        let codexRelease = Hook(socket: release.socket, app: release.app, agent: .codex)
        let codexDev = Hook(socket: dev.socket, app: dev.app, agent: .codex)
        func codexHooks() -> [String: [[String: Any]]] {
            (parsed(contents(codexFile))?["hooks"] as? [String: [[String: Any]]]) ?? [:]
        }
        func shape() -> String {
            codexHooks().sorted { $0.key < $1.key }.map { event, entries in
                event + " " + entries.map { entry in
                    let command = (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String ?? ""
                    return (entry["matcher"] as? String ?? "-") + (command.contains("echo agent=codex;") ? " codex" : " other")
                }.joined(separator: ", ")
            }.joined(separator: "; ")
        }
        check("codex hooks on: written into a new hooks.json", got: hooks(true, codexRelease, in: codexFolder),
              want: "written")
        check("codex hooks: four events, a matcher on tools and permissions, agent=codex", got: shape(),
              want: "PermissionRequest * codex; PreToolUse * codex; Stop - codex; UserPromptSubmit - codex")
        check("a new hooks.json is 0600", got: fileMode(codexFile), want: "600")
        check("codex hooks on again: no write", got: hooks(true, codexRelease, in: codexFolder), want: "none")
        _ = hooks(true, codexDev, in: codexFolder)
        _ = hooks(false, codexDev, in: codexFolder)
        check("the other variant's codex hooks come and go, these stay",
              got: hookCount(codexRelease, in: codexFile) + " " + hookCount(codexDev, in: codexFile), want: "4 0")
        let foreignCodex = #"{"description":"mine","hooks":{"PreToolUse":[{"matcher":"Bash","#
            + #""hooks":[{"command":"./guard.sh","type":"command"}]}]}}"#
        try? FileManager.default.removeItem(at: codexFile)
        try? FileManager.default.removeItem(at: codexBackup)
        try? ConfigMigration.create(codexFile, holding: Data(foreignCodex.utf8), mode: 0o644)
        _ = hooks(true, codexRelease, in: codexFolder)
        check("a codex hook goes after the user's own, so their trust index stays",
              got: codexHooks()["PreToolUse"]?.map { $0["matcher"] as? String ?? "-" }.joined(separator: " "),
              want: "Bash *")
        check("a 0644 hooks.json stays 0644, its backup is the first copy",
              got: fileMode(codexFile) + " " + (contents(codexBackup) == foreignCodex ? "first" : "other"),
              want: "644 first")
        _ = hooks(false, codexRelease, in: codexFolder)
        check("codex hooks off: the user's hooks.json is back, mode kept",
              got: (parsed(contents(codexFile)) == parsed(foreignCodex) ? "same " : contents(codexFile)) + fileMode(codexFile),
              want: "same 644")
        let noCodex = folder.appendingPathComponent("no-codex")
        check("no Codex folder: nothing written, no error, no folder made",
              got: hooks(true, codexRelease, in: noCodex) + " "
                + (FileManager.default.fileExists(atPath: noCodex.path) ? "made" : "absent"),
              want: "none absent")
        check("a missing Claude folder is still an error", got: hooks(true, release, in: noCodex), want: "failed")
        func sync(_ yaml: String) -> String {
            let decoded = try? YAMLDecoder().decode(Config.Voice.self, from: yaml.replacingOccurrences(of: "CODEX", with: codexFolder.path))
            guard let settings = decoded,
                  let target = targets(settings, hook: release).first(where: { $0.hook.agent == .codex }) else { return "-" }
            return reconcile(enabled: target.enabled, folders: target.folders, hook: target.hook).first?.change == .written
                ? "written " + hookCount(codexRelease, in: codexFile) : "none"
        }
        try? FileManager.default.removeItem(at: codexFile)
        // An agent that is off is taken out of its default folder: here, not ~/.codex.
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", codexFolder.path, 1)
        check("codex on with voice off installs nothing", got: sync("enabled: false\nagents: {codex: CODEX}"), want: "none")
        check("codex on with voice on installs", got: sync("agents: {claude: , codex: CODEX}"), want: "written 4")
        check("removing the codex key uninstalls", got: sync("agents: {claude: }"), want: "written 0")
        if let codexHome { setenv("CODEX_HOME", codexHome, 1) } else { unsetenv("CODEX_HOME") }
        func agents(_ yaml: String) -> String {
            guard let settings = try? YAMLDecoder().decode(Config.Voice.self, from: yaml) else { return "unreadable" }
            let on = targets(settings, hook: release).filter(\.enabled)
            return on.map { "\($0.hook.agent.rawValue) " + $0.folders.map(shown).joined(separator: ",") }
                .joined(separator: "; ") + (settings.unknownAgents.isEmpty ? "" : " ?" + settings.unknownAgents.joined(separator: ","))
                + (settings.refusedAgents == nil ? "" : " !")
        }
        check("no agents key: claude in ~/.claude", got: agents("enabled: true"), want: "claude ~/.claude")
        check("agents commented out: claude in ~/.claude", got: agents("agents:"), want: "claude ~/.claude")
        check("agents: {} is no agent", got: agents("agents: {}"), want: "")
        check("a folder, a list, an empty list",
              got: agents("agents: {claude: [~/a, ~/b], codex: ~/c}") + " | " + agents("agents: {claude: []}"),
              want: "claude ~/a,~/b; codex ~/c | claude ~/.claude")
        check("an unknown agent is set aside, and mini hooks nothing",
              got: agents("agents: {claude: , zork: ~/z, mini: }"), want: "claude ~/.claude ?zork")
        func spokenFor(_ yaml: String) -> String {
            guard let settings = try? YAMLDecoder().decode(Config.Voice.self, from: yaml) else { return "unreadable" }
            return CodingAgent.allCases.filter { settings.folders(of: $0) != nil }.map(\.rawValue).joined(separator: ",")
                + (settings.folderless.isEmpty ? "" : " ?" + settings.folderless.joined(separator: ","))
        }
        check("mini is spoken for only with its key",
              got: spokenFor("agents: {claude: }") + " | " + spokenFor("agents: {mini: }") + " | " + spokenFor("enabled: true"),
              want: "claude | mini | claude")
        check("a folder after mini is said and set aside, and mini stays on",
              got: spokenFor("agents: {mini: ~/m}") + " | " + spokenFor("agents: {mini: [~/a]}") + " | " + spokenFor("agents: {mini: []}"),
              want: "mini ?mini | mini ?mini | mini")
        check("a value that is not a folder: the default folder, said, and the rest still loads",
              got: agents("agents: {claude: {x: 1}}\nprogress: false") + " | " + agents("agents: [claude, codex]"),
              want: "claude ~/.claude ! | claude ~/.claude !")
        var withFolder = Config()
        withFolder.voice.agents[.codex] = ["~/codex-elsewhere"]
        check("--agent codex installs into voice.agents.codex",
              got: folders(["--install-claude-hooks", "--agent", "codex"], agent: .codex, config: withFolder).first?.path,
              want: NSHomeDirectory() + "/codex-elsewhere")
        try? FileManager.default.removeItem(at: folder)
        let event = #"{"hook_event_name":"Stop","session_id":"s"}"#
        func received(_ payload: String) -> String {
            let (pid, agent, body) = ClaudeVoice.split(Data(payload.utf8))
            return [pid.map { "\($0)" } ?? "-", ClaudeVoice.speaksFor(agent)?.rawValue ?? "ignored",
                    String(bytes: body, encoding: .utf8) == event ? "event" : "broken"].joined(separator: " ")
        }
        check("an event with no agent= line is Claude's", got: received("pid=42\n" + event), want: "42 claude event")
        check("agent=claude is Claude's", got: received("pid=42\nagent=claude\n" + event), want: "42 claude event")
        check("agent=codex is Codex's", got: received("pid=42\nagent=codex\n" + event), want: "42 codex event")
        check("agent=mini is mini's", got: received("pid=42\nagent=mini\n" + event), want: "42 mini event")
        check("an unknown agent is not spoken", got: received("pid=42\nagent=zork\n" + event), want: "42 ignored event")
        check("a mini command is said like a Codex one",
              got: CodingAgent.mini.progress(tool: "Bash", input: ["command": "cd app && python -m pytest -x"])?.text,
              want: "I'm running the tests")
        func thread(_ json: String) -> String {
            let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            return ClaudeVoice.isSubagent(parsed) ? "subagent" : "main"
        }
        check("a Codex event with a null agent_id is the main thread", got: thread(#"{"agent_id":null}"#), want: "main")
        check("a Codex event with an agent_id is a subagent's", got: thread(#"{"agent_id":"a1"}"#), want: "subagent")
        check("an event with no header is Claude's", got: received(event), want: "- claude event")
        check("one session id under two agents is two sessions",
              got: "\(Set([ClaudeVoice.key(.claude, "s"), ClaudeVoice.key(.codex, "s"), ClaudeVoice.key(.claude, "s")]).count)",
              want: "2")
        print("\n\(passed)/\(total)")
        return passed == total ? 0 : 1
    }

    static func spoken(transcript path: String, config: Config) -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let ended = ClaudeSpeakable.lastTurn(transcript: url) else {
            print("✗ no assistant turn in \(path)")
            return 1
        }
        var said: ClaudeVoice.Spoken?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            said = await ClaudeVoice.spoken(
                turn: ended, written: nil, settings: config.voice, config: config,
                toned: ClaudeVoice.remote(config.voice, config) != nil
            )
            done.signal()
        }
        done.wait()
        let redacted = ClaudeSpeakable.spokenRedacted
        print("recap:   \(ended.recap.map(redacted) ?? "(none)")")
        print("cleaned: \(redacted(ClaudeSpeakable.clean(ended.answer)))")
        print("spoken:  \(said.map { redacted($0.text) } ?? "(nothing)")")
        print("tone:    \(said?.tone.map(redacted) ?? "(none)")")
        return 0
    }

    /// One `PreToolUse` payload through the explain prompt, as the app would say it.
    static func explain(event json: String, context: String?, config: Config) -> Int32 {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = event["tool_name"] as? String else {
            print("✗ not a hook payload")
            return 2
        }
        guard let prompt = VoicePrompt.explain.current else {
            print("✗ \(VoicePrompt.explain.builtIn.path) is missing")
            return 1
        }
        let input = event["tool_input"] as? [String: Any] ?? [:]
        let named = config.voice.model.trimmingCharacters(in: .whitespaces)
        let model = config.model(named: named) ?? config.model(for: .general)
        var said = ""
        let opening = VoicePrompt.opening(count: VoicePrompt.openings(in: prompt.text), after: nil)
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let raw = try? await LLM.complete(
                system: prompt.text,
                user: ClaudeSpeakable.explainInput(tool: tool, input: input, context: context, opening: opening),
                json: false, maxTokens: 60, config: model
            )
            said = raw.map { ClaudeSpeakable.spokenRedacted(ClaudeSpeakable.clean(LLM.stripThinking($0))) } ?? ""
            done.signal()
        }
        done.wait()
        let plain = ClaudeSpeakable.progress(tool: tool, input: input)?.text
        print("plain:     \(plain.map(ClaudeSpeakable.spokenRedacted) ?? "(silent)")")
        print(String(format: "explained: %@  (%.1fs)", said.isEmpty ? "(failed)" : said, Date().timeIntervalSince(started)))
        return 0
    }

    /// `tone` replaces the whole instructions, so they can be tried as written.
    static func say(
        _ text: String, config: Config, tone: String? = nil, voice: String? = nil, output: String? = nil
    ) -> Never {
        let text = ClaudeSpeakable.spokenRedacted(text)
        if let output {
            guard let remote = ClaudeVoice.remote(config.voice, config) else {
                print("✗ --output needs a remote voice: set voice.speech to a model under models:")
                exit(1)
            }
            save(text, to: output, remote: remote, tone: tone, voice: voice ?? config.voice.speechVoices.first ?? "")
        }
        Task { @MainActor in
            let speaker = Speaker()
            speaker.localVoice = config.voice.localVoice
            speaker.localPlacement = PocketTtsModelPlacement(rawValue: config.voice.localPlacement) ?? .gpu
            speaker.speed = config.voice.speed
            speaker.remote = ClaudeVoice.remote(config.voice, config)
            let started = Date()
            let style = (voice ?? config.voice.speechVoices.first).map {
                Speaker.Style(voice: $0, tone: tone ?? ClaudeSpeakable.instructions(base: config.voice.speechTone, shift: nil))
            }
            print("tone:  \(style?.tone ?? "(PocketTTS has none)")")
            if let remote = speaker.remote {
                print("voice: \(remote.name) (\(remote.model)), \(style?.voice ?? "-")")
            } else {
                await speaker.warm()
                print(String(format: "PocketTTS loaded in %.1fs", Date().timeIntervalSince(started)))
            }
            speaker.say(text, style: style)
            await speaker.waitUntilIdle()
            print(String(format: "done in %.1fs", Date().timeIntervalSince(started)))
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// The remote voice into a 24 kHz WAV instead of the speakers: a clip to
    /// clone a PocketTTS voice from.
    private static func save(_ text: String, to path: String, remote: ModelSpec, tone: String?, voice: String) -> Never {
        Task { @MainActor in
            var samples: [Float] = []
            do {
                let timing = try await RemoteSpeech.stream(
                    ClaudeSpeakable.speakable(text), voice: voice, tone: tone, speed: 1, config: remote
                ) { piece in
                    samples += piece
                    return true
                }
                // A WAV's sizes are 32-bit: about 12 hours of 24 kHz audio.
                guard samples.count < Int(UInt32.max / 2) - 64 else { throw CocoaError(.fileWriteFileExists) }
                try wav(samples, rate: RemoteSpeech.sampleRate).write(to: URL(fileURLWithPath: path))
                print(String(format: "saved %@: %.1fs of audio, %@ at %d Hz, first sound %.2fs",
                             path, Double(samples.count) / Double(RemoteSpeech.sampleRate),
                             timing.contentType, timing.rate, timing.firstAudio))
                exit(0)
            } catch {
                print("✗ \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func wav(_ samples: [Float], rate: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for sample in samples { put(Int16(max(-1, min(1, sample)) * 32_767)) }
        return data
    }
}
