import AppKit
import Foundation
import Yams

/// The terminal side of `ClaudeVoice`.
///
///   --speak-event               what the hooks run; stdin → the app's socket
///   --install-claude-hooks      into every `claude.folders` entry
///   --uninstall-claude-hooks
///   --claude-voice-test <cases> score the text rules, no audio
///   --claude-spoken <file>      what the last turn of a transcript would say
///   --claude-say "<text>"       say it through Kokoro
enum ClaudeHooksCommand {

    static let marker = "--speak-event"
    static let events = ["PreToolUse", "Stop", "Notification", "UserPromptSubmit"]

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
            var sent = 0
            while sent < raw.count {
                let wrote = write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard wrote > 0 else { break }
                sent += wrote
            }
        }
        return 0
    }

    // MARK: - Install

    static func folders(_ arguments: [String], config: Config?) -> [URL] {
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
        return (config?.claude ?? Config.Claude()).folderURLs
    }

    /// Names our hook in `settings.json`, for uninstall. Hooks written by older
    /// builds carry `marker` instead.
    static let tag = "parrotflow-speak-event"

    /// `nc` to the app's socket, not the app binary. The binary in a hook
    /// blocked Claude once that build was uninstalled, and a build that does
    /// not know `--speak-event` starts a second menu bar app on every tool
    /// call. `nc` exits in about 10 ms either way, and `exit 0` keeps a missing
    /// app silent. `$PPID` is the Claude process, which `SpeakingFrame` walks
    /// up from to find the window to frame. nil for a `.build` binary: it has no bundle id, so its
    /// socket path would be the release app's.
    static var hookCommand: String? {
        guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
              path.contains(".app/Contents/MacOS/") else { return nil }
        let socket = ClaudeVoice.socketURL.path
        return "[ -S '\(socket)' ] && { echo \"pid=$PPID\"; cat; } | /usr/bin/nc -U -w 1 '\(socket)' >/dev/null 2>&1;"
            + " exit 0 # \(tag)"
    }

    static func install(folders: [URL]) -> Int32 {
        guard let command = hookCommand else {
            print("✗ Run this from the installed app, not from .build:")
            print("  /Applications/\(AppVariant.isDev ? "ParrotFlowDev" : "ParrotFlow").app/Contents/MacOS/ParrotFlow --install-claude-hooks")
            return 1
        }
        var failed = false
        for folder in folders {
            failed = !edit(folder: folder) { hooks in
                for event in events {
                    var entries = withoutOurs(hooks[event])
                    var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 2]]]
                    if event == "PreToolUse" { entry["matcher"] = "*" }
                    entries.append(entry)
                    hooks[event] = entries
                }
            } || failed
        }
        if !failed {
            print("  Claude Code reads hooks at the start of a session, so restart open sessions.")
        }
        return failed ? 1 : 0
    }

    static func uninstall(folders: [URL]) -> Int32 {
        var failed = false
        for folder in folders {
            failed = !edit(folder: folder) { hooks in
                for event in events {
                    let entries = withoutOurs(hooks[event])
                    hooks[event] = entries.isEmpty ? nil : entries
                }
            } || failed
        }
        return failed ? 1 : 0
    }

    private static func withoutOurs(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            var entry = entry
            let kept = (entry["hooks"] as? [[String: Any]] ?? []).filter {
                let command = $0["command"] as? String ?? ""
                return !(command.contains(tag) || command.contains(marker))
            }
            if kept.isEmpty { return nil }
            entry["hooks"] = kept
            return entry
        }
    }

    /// Reads `settings.json`, changes `hooks`, writes it back. Keeps the first
    /// copy it ever saw as `settings.json.parrotflow-backup`.
    private static func edit(folder: URL, _ change: (inout [String: Any]) -> Void) -> Bool {
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            print("✗ \(shown): no such folder")
            return false
        }
        let file = folder.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("✗ \(shown)/settings.json is not a JSON object — left alone")
                return false
            }
            settings = read
            let backup = folder.appendingPathComponent("settings.json.parrotflow-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? data.write(to: backup)
            }
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        change(&hooks)
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try (data + Data("\n".utf8)).write(to: file, options: .atomic)
        } catch {
            print("✗ \(shown)/settings.json: \(error.localizedDescription)")
            return false
        }
        print("✓ \(shown)/settings.json")
        return true
    }

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
        struct Summary: Decodable { var name: String; var lines: [String]; var want: String? }
        var summary: [Summary] = []

        enum CodingKeys: String, CodingKey {
            case clean, progress, turns, parse, capped, redacted, naming, grounded, speakable, spoken, summary
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
        for item in cases.naming {
            let said = ClaudeVoice.names(
                otherSpokeLast: item.otherSpokeLast, quietFor: item.quietFor, inFront: item.inFront
            )
            check(item.name, got: said ? "named" : "not named", want: item.named ? "named" : "not named")
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
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 6))!
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
                turn: ended, written: nil, settings: config.claude, config: config,
                toned: ClaudeVoice.remote(config.claude, config) != nil
            )
            done.signal()
        }
        done.wait()
        print("recap:   \(ended.recap ?? "(none)")")
        print("cleaned: \(ClaudeSpeakable.clean(ended.answer))")
        print("spoken:  \(said?.text ?? "(nothing)")")
        print("tone:    \(said?.tone ?? "(none)")")
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
        let input = event["tool_input"] as? [String: Any] ?? [:]
        let named = config.claude.model.trimmingCharacters(in: .whitespaces)
        let model = config.model(named: named) ?? config.model(for: .general)
        var said = ""
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let raw = try? await LLM.complete(
                system: ClaudeSpeakable.explainPrompt,
                user: ClaudeSpeakable.explainInput(tool: tool, input: input, context: context),
                json: false, maxTokens: 60, config: model
            )
            said = raw.map { ClaudeSpeakable.clean(LLM.stripThinking($0)) } ?? ""
            done.signal()
        }
        done.wait()
        print("plain:     \(ClaudeSpeakable.progress(tool: tool, input: input)?.text ?? "(silent)")")
        print(String(format: "explained: %@  (%.1fs)", said.isEmpty ? "(failed)" : said, Date().timeIntervalSince(started)))
        return 0
    }

    /// `tone` replaces the whole instructions, so they can be tried as written.
    static func say(
        _ text: String, config: Config, tone: String? = nil, voice: String? = nil, output: String? = nil
    ) -> Never {
        if let output, let remote = ClaudeVoice.remote(config.claude, config) {
            save(text, to: output, remote: remote, tone: tone, voice: voice ?? config.claude.speechVoices.first ?? "")
        }
        Task { @MainActor in
            let speaker = Speaker()
            speaker.voice = config.claude.voice
            speaker.speed = config.claude.speed
            speaker.remote = ClaudeVoice.remote(config.claude, config)
            let started = Date()
            let style = (voice ?? config.claude.speechVoices.first).map {
                Speaker.Style(voice: $0, tone: tone ?? config.claude.speechTone)
            }
            print("tone:  \(style?.tone ?? "(Kokoro has none)")")
            if let remote = speaker.remote {
                print("voice: \(remote.name) (\(remote.model)), \(style?.voice ?? "-")")
            } else {
                await speaker.warm()
                print(String(format: "Kokoro loaded in %.1fs", Date().timeIntervalSince(started)))
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
