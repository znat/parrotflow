import AppKit
import FluidAudio
import ApplicationServices

/// The coding agent a hook event comes from: Claude Code, Codex, or mini-swe-agent
/// through the plugin in `integrations/mini-swe-agent`.
enum CodingAgent: String, CaseIterable {
    case claude, codex, mini

    func progress(tool: String, input: [String: Any]) -> ClaudeSpeakable.Line? {
        switch self {
        case .claude: ClaudeSpeakable.progress(tool: tool, input: input)
        case .codex, .mini: CodexSpeakable.progress(tool: tool, input: input)
        }
    }

    /// The turn that just ended, read from this agent's own transcript format.
    func lastTurn(transcript: URL, tailBytes: Int = 512 * 1024) -> ClaudeSpeakable.TurnEnd? {
        switch self {
        case .claude: ClaudeSpeakable.lastTurn(transcript: transcript, tailBytes: tailBytes)
        case .codex: CodexSpeakable.lastTurn(transcript: transcript, tailBytes: tailBytes)
        case .mini: nil
        }
    }

    func title(transcript: URL) -> String? {
        switch self {
        case .claude: ClaudeSpeakable.title(transcript: transcript)
        case .codex: CodexSpeakable.title(rollout: transcript)
        case .mini: nil
        }
    }

    func latestSummary(transcript: URL) -> String? {
        switch self {
        case .claude: ClaudeSpeakable.latestSummary(transcript: transcript)
        case .codex: CodexSpeakable.latestSummary(transcript: transcript)
        case .mini: nil
        }
    }

    /// The file in each config folder that holds this agent's hooks.
    var hooksFile: String { self == .codex ? "hooks.json" : "settings.json" }

    /// The events the app hooks, with the matcher an event takes. Empty: no hooks to install.
    var hookEvents: [(name: String, matcher: String?)] {
        switch self {
        case .claude: [("PreToolUse", "*"), ("Stop", nil), ("Notification", nil), ("UserPromptSubmit", nil)]
        case .codex: [("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PermissionRequest", "*"), ("Stop", nil)]
        case .mini: []
        }
    }

    /// The agent's own app, which shows its sessions in one window.
    var desktopApp: String? {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        case .mini: nil
        }
    }

    /// The agents whose hooks the app installs. mini speaks through a plugin instead.
    static var hooked: [CodingAgent] { allCases.filter { !$0.hookEvents.isEmpty } }

    /// Where the hooks go when `voice.agents` names no folder. An app opened
    /// from the Finder does not see a `CODEX_HOME` set in a shell profile.
    var defaultFolders: [String] {
        switch self {
        case .claude: ["~/.claude"]
        case .codex: [ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""]
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "~/.codex" : $0 }
        case .mini: []
        }
    }
}

/// Speaks the coding agents' progress and answers.
///
/// Claude Code runs `ParrotFlow --speak-event` from a hook. That process
/// passes the hook's JSON to this socket and exits, so the hook never waits.
/// See `ClaudeHooksCommand`.
final class ClaudeVoice {

    static var socketURL: URL { AppVariant.supportDirectory.appendingPathComponent("claude.sock") }

    /// Set by the app: the voice is held from hotkey down until this is false.
    var isRecording: () -> Bool = { false }
    /// Set by the app: what the pill says about the voice, or nil to take it away. Sent on
    /// every change, and each second while there is something to say.
    var onVoicePill: (VoicePill?) -> Void = { _ in }

    private let speaker = Speaker()
    /// Answers, notifications and questions. Progress lines are said or dropped, never queued.
    private var queue = VoiceQueue() { didSet { pillSoon() } }
    /// Your pause. Set and cleared together with the `.user` hold.
    private(set) var paused: VoicePause?
    private var pauseEnd: Timer?
    private var wakeWatch: NSObjectProtocol?
    static let pausedKey = "voice.pausedUntil"
    /// While `voice.pause_during_calls` is on.
    private var callWatch: CallWatch?
    private var call: VoiceCall? { didSet { pillSoon() } }
    /// The app holding the voice, for the menu.
    var callApp: String? { if case .on(let app)? = call { app } else { nil } }
    var waitingCount: Int { queue.waiting.count }
    /// For the menu bar icon: answers kept by a pause or a call.
    var heldCount: Int { queue.holds.isDisjoint(with: [.user, .call]) ? 0 : queue.waiting.count }
    /// The Speaker line saying `queue.playing`.
    private var answerLine: Int?
    private var dictationWatch: Timer?
    private let frame = SpeakingFrame()
    private var settings = Config.Voice()
    private var config = Config()
    private var listener: SocketListener?
    private var warmedVoice = ""
    /// Each hook problem is logged once, not on every reload.
    private var hookProblems: Set<String> = []
    /// Agents, events and transcripts this build skips, each logged once.
    private var skipped: Set<String> = []
    private var lastProgressAt = Date.distantPast
    private var lastKind: ClaudeSpeakable.Kind?
    /// By `key(_:_:)`, so two agents' session ids never meet.
    private var sessions: [String: Session] = [:]
    /// Per session, bumped by a new prompt, so that session's answer still
    /// being rewritten is dropped. Other sessions' answers are kept.
    private var turns: [String: Int] = [:]
    /// The turn whose answer was already said from its recap, per session.
    private var recapTurns: [String: Int] = [:]
    private var voices: [String: String] = [:]
    /// The same, for the local voice's own list.
    private var localVoices: [String: String] = [:]
    private var lastSpokenSession: String?
    private var lastSpokenAt: Date?
    private var lastIntroduction: Int?
    /// The session the pill names.
    private var pillSession: String?
    /// Gone to: no "Go to session" for it until it stops speaking.
    private var pillDismissed: String?
    private var pill: VoicePill?
    private var pillQueued = false
    private var pillCheck: Timer?
    private var pillLinger: DispatchWorkItem?
    /// The opening the last answer used, across sessions: answers are heard in a row.
    private var lastAnswerOpening: Int?
    /// Bumped per progress line, so a slow explanation of an older call is dropped.
    private var progressSeq = 0
    /// Past this, the call being explained is likely over.
    private let explainLimit: TimeInterval = 5

    private struct Session {
        let agent: CodingAgent
        var project: String
        var account: String?
        var seen: Date
        /// The agent's process, from the hook's `$PPID`.
        var pid: pid_t?
        var transcript: URL?
        /// The latest request, and the reminder made from it.
        var task: String?
        var reminder: String?
        var reminding = false
        /// The last explained progress lines, oldest first, and the opening the last one used.
        var progress: [String] = []
        var opening: Int?
        var heard: Date?
        var hostPid: pid_t?
        /// The pane, or else the window, this session lives in, kept once known.
        var window: AXUIElement?
        /// Where that pane or window was, to find it again when Ghostty rebuilds it.
        var rect: CGRect?
        /// The language of the latest request that was long enough to tell.
        var language: String?
        /// A few words about the task, from the latest rewrite.
        var label: String?
        /// Behind Codex's shared app server, the window is found by its title.
        var byTitle = false
        /// No single window had that title; tried again after the next prompt.
        var titleMissed = false
    }

    struct Spoken: Equatable {
        var text: String
        var tone: String?
        var language = "en"
        var task: String?
    }

    private let progressInterval: TimeInterval = 6
    private let readingInterval: TimeInterval = 30
    private let activeWindow: TimeInterval = 600

    func apply(_ config: Config) {
        self.config = config
        settings = config.voice
        speaker.speed = settings.speed
        speaker.remote = Self.remote(settings, config)
        speaker.localVoice = settings.localVoice
        speaker.localPlacement = PocketTtsModelPlacement(rawValue: settings.localPlacement) ?? .gpu
        frame.color = ContextIdentity.nsColor(config.feedback.primaryColor)
        if !settings.frame { frame.hide(now: true) }
        speaker.onSpeakingSession = { [weak self] id in self?.frameSession(id) }
        speaker.onLevel = { [weak self] rms in self?.frame.level(rms) }
        speaker.onLineDone = { [weak self] line in self?.lineDone(line) }
        if settings.enabled, listener == nil {
            listener = SocketListener(path: Self.socketURL.path) { [weak self] data in
                Task { @MainActor in self?.receive(data) }
            }
            let stored = UserDefaults.standard.object(forKey: Self.pausedKey) as? Date
            if let restored = VoicePause.restored(stored, now: Date()) {
                pause(restored, by: "restored")
            } else if stored != nil {
                UserDefaults.standard.removeObject(forKey: Self.pausedKey)
            }
        } else if !settings.enabled, listener != nil {
            listener = nil
            // The saved pause stays: turning the voice back on restores it.
            paused = nil
            pauseEnd?.invalidate()
            pauseEnd = nil
            queue = VoiceQueue()
            call = nil
            answerLine = nil
            dictationWatch?.invalidate()
            dictationWatch = nil
            speaker.stop()
        }
        watchCalls()
        warmIfNeeded()
        syncHooks()
    }

    private func watchCalls() {
        let wanted = settings.enabled && settings.pauseDuringCalls
        if wanted, callWatch == nil {
            let watch = CallWatch()
            watch.onEvent = { [weak self] event in self?.callEvent(event) }
            callWatch = watch
        } else if !wanted, let watch = callWatch {
            watch.stop()
            callWatch = nil
            if callApp != nil {
                call = nil
                release(.call)
            }
        }
    }

    /// A call holds the voice. Over, it leaves the voice paused while answers wait.
    /// Resumed during the call, it is not held again until the next call.
    private func callEvent(_ event: CallState.Event) {
        switch event {
        case .started(let app):
            Log.write("claude voice: call started (\(app)), held" + (paused == nil ? "" : ", already paused"))
            call = .on(app)
            hold(.call)
        case .ended(let app):
            guard callApp != nil else { return Log.write("claude voice: call over (\(app)), not held") }
            Log.write("claude voice: call over (\(app)), \(queue.waiting.count) waiting")
            call = nil
            if paused == nil, !queue.waiting.isEmpty {
                pause(.untilResumed, by: "call over")
                call = .over
            }
            release(.call)
        }
    }

    /// The call-over pill's Not now: the voice stays paused, the pill goes.
    func notNow() {
        guard call == .over else { return }
        call = .dismissed
        Log.write("claude voice: call over, not now, \(queue.waiting.count) waiting")
    }

    /// The hooks follow `voice.enabled` and `voice.agents`, so nobody runs `--install-claude-hooks`.
    private func syncHooks() {
        guard let current = ClaudeHooksCommand.Hook.current else { return }
        for (hook, enabled, folders) in ClaudeHooksCommand.targets(settings, hook: current) {
            let name = hook.agent.rawValue + " hooks"
            for (folder, change) in ClaudeHooksCommand.reconcile(enabled: enabled, folders: folders, hook: hook) {
                switch change {
                case .unchanged: break
                case .written:
                    let trust = enabled && hook.agent == .codex ? "; \(ClaudeHooksCommand.codexTrust)" : ""
                    Log.write("\(name): \(enabled ? "installed in" : "removed from") \(ClaudeHooksCommand.shown(folder))\(trust)")
                case .failed(let why):
                    if hookProblems.insert(why).inserted { Log.write("\(name): \(why)") }
                }
            }
        }
    }

    /// The local voice is warmed when it will speak first: no remote voice,
    /// or progress lines kept local. Only once a hook was heard, so a Mac
    /// without Claude Code hooks never loads it.
    private func warmIfNeeded() {
        let warm = settings.localPlacement + ":" + settings.localVoice
        guard settings.enabled, !sessions.isEmpty, speaker.remote == nil || settings.progressLocal,
              warmedVoice != warm else { return }
        warmedVoice = warm
        Task { @MainActor in await speaker.warm() }
    }

    /// The model `voice.speech` names, when it can speak `/audio/speech`.
    static func remote(_ settings: Config.Voice, _ config: Config) -> ModelSpec? {
        let name = settings.speech.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let spec = config.model(named: name), spec.api == .openai else { return nil }
        return spec
    }

    /// The hotkey went down: the voice stops now and picks up where it
    /// stopped once the dictation is over.
    func silence() {
        guard settings.enabled else { return }
        hold(.dictation)
        guard dictationWatch == nil else { return }
        // Called before the microphone opens, so the first look is half a second on.
        let watch = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard !self.isRecording() else { return }
            timer.invalidate()
            self.dictationWatch = nil
            self.release(.dictation)
        }
        // Common modes: an open menu would stall a default-mode timer until it closes.
        RunLoop.main.add(watch, forMode: .common)
        dictationWatch = watch
    }

    /// Every session waits until `resume` or the deadline. Pausing again replaces the deadline.
    func pause(_ pause: VoicePause = .untilResumed, by cause: String = "pill") {
        guard settings.enabled else { return }
        paused = pause
        if callApp == nil { call = nil }
        UserDefaults.standard.set(pause.stored, forKey: Self.pausedKey)
        if !queue.holds.contains(.user) { hold(.user) }
        armPauseEnd()
        Log.write("claude voice: paused \(pause.phrase(now: Date())) (\(cause)), \(queue.waiting.count) waiting")
    }

    /// Also lets a call's hold go: the voice plays during the call.
    func resume(by cause: String = "pill") {
        guard paused != nil || callApp != nil else { return }
        Log.write("claude voice: resumed (\(cause)), \(queue.waiting.count) waiting")
        let held = callApp != nil
        call = nil
        if held { release(.call) }
        if paused != nil { endPause() }
    }

    private func endPause() {
        paused = nil
        if callApp == nil { call = nil }
        pauseEnd?.invalidate()
        pauseEnd = nil
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        release(.user)
    }

    /// One timer to the deadline, and a look on wake: a timer does not count the time asleep.
    private func armPauseEnd() {
        pauseEnd?.invalidate()
        pauseEnd = nil
        guard let deadline = paused?.deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in self?.checkPauseEnd() }
        RunLoop.main.add(timer, forMode: .common)
        pauseEnd = timer
        guard wakeWatch == nil else { return }
        wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkPauseEnd() }
    }

    private func checkPauseEnd() {
        guard let deadline = paused?.deadline else { return }
        guard deadline <= Date() else { return armPauseEnd() }
        Log.write("claude voice: pause ended at \(VoicePause.time(deadline)), \(queue.waiting.count) waiting")
        endPause()
    }

    private func hold(_ cause: VoiceQueue.Hold) {
        let stopped = speaker.pause()
        let playing = queue.playing
        queue.hold(cause, stoppedAt: stopped?.line == answerLine ? stopped?.sentence : nil)
        answerLine = nil
        if let playing, let held = queue.waiting.first {
            Log.write("claude voice: held (\(cause.rawValue)), \(project(of: playing.session)) back in front "
                + "at sentence \(held.resume + 1) of \(held.sentences.count)")
        } else if !queue.waiting.isEmpty {
            Log.write("claude voice: held (\(cause.rawValue)), \(queue.waiting.count) waiting")
        }
    }

    private func release(_ cause: VoiceQueue.Hold) {
        guard queue.holds.contains(cause) else { return }
        queue.release(cause)
        if !queue.waiting.isEmpty {
            let still = queue.holds.map(\.rawValue).sorted().joined(separator: ", ")
            Log.write("claude voice: released (\(cause.rawValue)), \(queue.waiting.count) waiting"
                + (still.isEmpty ? "" : ", still held (\(still))"))
        }
        playNext()
    }

    private func enqueue(_ text: String, session: String, progress: Bool = false, tone: String? = nil) {
        let voice = style(for: session, progress: progress, tone: tone)
        queue.add(session: session, text: ClaudeSpeakable.spokenRedacted(text), style: voice.style,
                  localVoice: voice.local)
        playNext()
    }

    /// Says the next answer when none plays and nothing holds the voice. The
    /// session's name goes on a line of its own, so it never shifts the
    /// sentence a held answer resumes from.
    private func playNext() {
        guard let entry = queue.startNext() else { return }
        // Progress lines give way; another session's answer keeps its place.
        speaker.dropProgress()
        let lead = opening(for: entry.session)
        if entry.resume > 0 {
            Log.write("claude voice: resumed \(project(of: entry.session)) at sentence \(entry.resume + 1) "
                + "of \(entry.sentences.count)")
        }
        // Whole, so scripts/tone-play.sh can replay it.
        Log.write("claude voice: said: \((lead + entry.remaining.joined(separator: " ")).prefix(800))")
        speaker.say(lead, style: entry.style, session: entry.session, localVoice: entry.localVoice)
        answerLine = speaker.say(sentences: entry.remaining, style: entry.style, session: entry.session,
                                 localVoice: entry.localVoice)
    }

    private func lineDone(_ line: Int) {
        guard line == answerLine else { return }
        answerLine = nil
        if let id = queue.playing?.id { queue.finish(id) }
        playNext()
    }

    private func project(of session: String) -> String {
        sessions[session]?.project ?? session
    }

    // MARK: - Events

    /// Hooks send `pid=<the agent's pid>` and `agent=<name>` lines, then the
    /// event. Hooks from older builds send no `agent=` line: that is Claude Code.
    static func split(_ data: Data) -> (pid: pid_t?, agent: String, body: Data) {
        var pid: pid_t?
        var agent = CodingAgent.claude.rawValue
        var rest = data
        let pidField = Data("pid=".utf8), agentField = Data("agent=".utf8)
        while rest.starts(with: pidField) || rest.starts(with: agentField), let newline = rest.firstIndex(of: 10) {
            let line = String(bytes: rest[rest.startIndex..<newline], encoding: .utf8) ?? ""
            if rest.starts(with: pidField) {
                pid = pid_t(line.dropFirst(pidField.count))
            } else {
                agent = String(line.dropFirst(agentField.count))
            }
            rest = rest[rest.index(after: newline)...]
        }
        return (pid, agent, Data(rest))
    }

    /// The agent whose events this build speaks. Another agent's events and
    /// transcripts differ, so the Claude rules would say wrong lines.
    static func speaksFor(_ name: String) -> CodingAgent? {
        CodingAgent(rawValue: name)
    }

    static func key(_ agent: CodingAgent, _ session: String) -> String {
        agent.rawValue + ":" + session
    }

    private func receive(_ data: Data) {
        let (pid, named, body) = Self.split(data)
        guard settings.enabled,
              let event = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = event["hook_event_name"] as? String else { return }
        guard let agent = Self.speaksFor(named) else {
            return skip("agent " + named, "events from agent \"\(named.prefix(40))\" are not spoken by this build")
        }
        // mini has no hooks to take out, so its events still come when its key is gone.
        guard settings.folders(of: agent) != nil else {
            return skip("agent off " + named, "\(named) events are not spoken: voice.agents has no \(named) key")
        }
        if agent == .codex, Self.isSubagent(event) {
            return skip("codex subagent", "Codex subagent events are not spoken")
        }
        let id = Self.key(agent, event["session_id"] as? String ?? "")
        note(session: id, agent: agent, event: event, pid: pid)
        warmIfNeeded()
        let transcript = Self.transcript(event)

        switch name {
        case "UserPromptSubmit":
            let prompt = event["prompt"] as? String ?? ""
            // Not typed: the focused pane may be another session's.
            if ClaudeSpeakable.typed(prompt) {
                findByTitle(id, prompted: true)
                pinWindow(id)
                if let language = ClaudeSpeakable.language(of: prompt) { sessions[id]?.language = language }
                if !prompt.isEmpty {
                    Task.detached {
                        let latest = transcript.flatMap { agent.latestSummary(transcript: $0) }
                        let title = transcript.flatMap { agent.title(transcript: $0) }
                        await MainActor.run { [weak self] in self?.remind(id, request: prompt, latest: latest, title: title) }
                    }
                }
            }
            turns[id, default: 0] += 1
            if speaker.speakingSession == id { Log.write("claude voice: stopped by a new prompt") }
            let dropped = queue.drop(session: id)
            if dropped > 0 { Log.write("claude voice: a new prompt dropped \(dropped) of \(project(of: id))'s lines") }
            speaker.stop(session: id)
            playNext()
        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? ""
            let input = event["tool_input"] as? [String: Any] ?? [:]
            // The desktop app's recap comes before the closing message is
            // written, so saying it here is seconds ahead of `Stop`.
            if tool.hasSuffix("wrap_up"), let recap = (input["recap"] as? String), !recap.isEmpty {
                recapTurns[id] = turns[id, default: 0]
                let ended = ClaudeSpeakable.TurnEnd(answer: "", recap: recap, ask: input["ask"] as? String)
                answer(ended, written: nil, session: id, settle: 0)
                return
            }
            guard settings.progress, let line = agent.progress(tool: tool, input: input) else { return }
            progress(line, session: id, tool: tool, input: input, transcript: transcript)
        case "Notification":
            guard let message = event["message"] as? String,
                  let said = ClaudeSpeakable.notification(message) else { return }
            enqueue(said, session: id)
        case "PermissionRequest":
            let said = CodexSpeakable.waiting(tool: event["tool_name"] as? String ?? "",
                                              input: event["tool_input"] as? [String: Any] ?? [:])
            enqueue(said, session: id)
        case "Stop":
            guard event["stop_hook_active"] as? Bool != true else { return }
            if recapTurns[id] == turns[id, default: 0] {
                recapTurns[id] = nil
                return
            }
            answer(nil, transcript: transcript, written: event["last_assistant_message"] as? String,
                   session: id, settle: 0.4)
        default:
            skip(agent.rawValue + " " + name, "\(agent.rawValue) event \(name.prefix(40)) is not spoken")
        }
    }

    /// A Codex subagent's thread would speak as a session of its own. Codex
    /// writes absent optional fields as null.
    static func isSubagent(_ event: [String: Any]) -> Bool {
        (event["agent_id"] as? String)?.isEmpty == false
    }

    private func skip(_ key: String, _ why: String) {
        if skipped.insert(key).inserted { Log.write("claude voice: " + why) }
    }

    /// The event's transcript, nil when it has none or it is a Codex rollout
    /// compressed to `.jsonl.zst`: macOS has no zstd decoder.
    static func transcript(_ event: [String: Any]) -> URL? {
        guard let path = (event["transcript_path"] as? String)?.nilIfEmpty, !path.hasSuffix(".zst") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func progress(
        _ line: ClaudeSpeakable.Line, session: String,
        tool: String = "", input: [String: Any] = [:], transcript: URL? = nil
    ) {
        let now = Date()
        if !line.urgent {
            // Progress is for someone watching; away, only answers and asks are said.
            if !watching(session) { return }
            if !queue.takesProgress || speaker.isSpeaking { return }
            if now.timeIntervalSince(lastProgressAt) < progressInterval { return }
            if line.kind == .read, lastKind == .read,
               now.timeIntervalSince(lastProgressAt) < readingInterval { return }
        }
        lastProgressAt = now
        lastKind = line.kind
        progressSeq += 1
        guard settings.explain, config.llmEnabled, !line.urgent, !tool.isEmpty,
              let prompt = VoicePrompt.explain.current else {
            // A question is worth hearing after a dictation, so it waits its turn.
            if line.urgent { return enqueue(line.text, session: session, progress: true) }
            return sayProgress(line.text, session: session)
        }
        let mine = progressSeq
        let named = settings.model.trimmingCharacters(in: .whitespaces)
        let model = config.model(named: named) ?? config.model(for: .general)
        let limit = explainLimit
        let task = sessions[session]?.task
        let language = sessions[session]?.language ?? "en"
        let agent = sessions[session]?.agent
        let opening = VoicePrompt.opening(from: VoicePrompt.openings(in: prompt.text),
                                          after: sessions[session]?.opening)
        let saidBefore = sessions[session]?.progress ?? []
        Task.detached {
            let context = transcript.flatMap { agent?.lastTurn(transcript: $0, tailBytes: 128 * 1024) }?
                .latestText
            let started = Date()
            let raw = try? await LLM.complete(
                system: prompt.text,
                user: ClaudeSpeakable.explainInput(tool: tool, input: input, context: context, task: task,
                                                  language: language, opening: opening, said: saidBefore),
                json: false, maxTokens: 60, config: model
            )
            let elapsed = Date().timeIntervalSince(started)
            let said = raw.map { ClaudeSpeakable.clean(LLM.stripThinking($0), language: language) } ?? ""
            await MainActor.run { [weak self] in
                guard let self, mine == self.progressSeq, self.queue.takesProgress, !self.speaker.isSpeaking
                else { return }
                guard elapsed < limit else {
                    Log.write(String(format: "claude voice: explanation took %.1fs, dropped", elapsed))
                    return
                }
                if !said.isEmpty {
                    Log.write(String(format: "claude voice: %@ explained %@ in %.1fs", model.name, tool, elapsed))
                    self.sessions[session]?.progress = Array((saidBefore + [said]).suffix(3))
                    self.sessions[session]?.opening = opening
                }
                self.sayProgress(said.isEmpty ? line.text : said, session: session)
            }
        }
    }

    /// `settle`: the hook can arrive before the last line of the transcript is written.
    private func answer(
        _ ended: ClaudeSpeakable.TurnEnd?, transcript: URL? = nil, written: String?,
        session: String, settle: TimeInterval
    ) {
        let asked = turns[session, default: 0]
        let settings = settings
        let config = config
        let toned = speaker.remote != nil
        let request = sessions[session]?.task
        let language = sessions[session]?.language
        let agent = sessions[session]?.agent
        let opening = VoicePrompt.opening(from: VoicePrompt.openings(in: VoicePrompt.rewrite.current?.text ?? ""),
                                          after: lastAnswerOpening)
        Task.detached {
            if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
            let turn = ended ?? transcript.flatMap { agent?.lastTurn(transcript: $0) }
            let spoken = await Self.spoken(turn: turn, written: written, request: request, language: language,
                                           settings: settings, config: config, toned: toned, opening: opening)
            await MainActor.run { [weak self] in
                guard let self, let spoken else { return }
                guard asked == self.turns[session, default: 0] else {
                    Log.write("claude voice: dropped an answer — a new prompt came first in that session")
                    return
                }
                self.lastAnswerOpening = opening
                self.lastKind = nil
                if self.sessions[session]?.language == nil { self.sessions[session]?.language = spoken.language }
                if let task = spoken.task { self.sessions[session]?.label = task }
                self.enqueue(spoken.text, session: session, tone: spoken.tone)
            }
        }
    }

    /// What the end of a turn is worth saying, and how. Fails open: no
    /// model, or a model that fails, still says the recap or the first two
    /// sentences. `toned` asks the model for a tone even when the words
    /// need no rewrite.
    static func spoken(
        turn: ClaudeSpeakable.TurnEnd?, written: String?, request: String? = nil, language: String? = nil,
        settings: Config.Voice, config: Config, toned: Bool, opening: Int? = nil
    ) async -> Spoken? {
        let asked = request ?? turn?.prompt
        let written = turn.flatMap { $0.answer.isEmpty ? nil : $0.answer } ?? written ?? ""
        let language = language ?? asked.flatMap(ClaudeSpeakable.language(of:))
            ?? ClaudeSpeakable.language(of: written) ?? "en"
        let reply = ClaudeSpeakable.clean(written, language: language)
        let recap = turn?.recap.map {
            ClaudeSpeakable.clean([$0, turn?.ask].compactMap { $0 }.joined(separator: "\n"), language: language)
        }
        let plain = recap ?? ClaudeSpeakable.truncated(reply)
        guard !plain.isEmpty else { return nil }
        let base = toned ? settings.speechTone : nil
        let fallback = Spoken(text: plain, tone: base.map { ClaudeSpeakable.instructions(base: $0, shift: nil) },
                               language: language)
        guard config.llmEnabled else { return fallback }
        guard let prompt = VoicePrompt.rewrite.current else {
            Log.write("claude voice: \(VoicePrompt.rewrite.builtIn.path) is missing, saying it plain")
            return fallback
        }

        let named = settings.model.trimmingCharacters(in: .whitespaces)
        let model = config.model(named: named) ?? config.model(for: .general)
        let started = Date()
        do {
            let raw = try await LLM.complete(
                system: prompt.text,
                user: ClaudeSpeakable.rewriteInput(request: asked, reply: reply, recap: recap,
                                                   earlier: turn?.earlier, language: language,
                                                   opening: opening),
                json: true, maxTokens: 300, config: model
            )
            let parsed = ClaudeSpeakable.parseSpoken(LLM.stripThinking(raw))
            if !parsed.json {
                Log.write("claude voice: rewrite reply is not JSON (prompt: \(prompt.source.shown)), "
                    + (parsed.say.isEmpty ? "saying it plain" : "saying it as written"))
                if parsed.say.isEmpty { return fallback }
            }
            let said = ClaudeSpeakable.capped(ClaudeSpeakable.clean(parsed.say, language: language), limit: 480, count: 4)
            let ground = ClaudeSpeakable.grounded(said, in: [reply, recap ?? "", asked ?? ""].joined(separator: " "))
            // Translated, the words cannot overlap, so the check would always say no.
            let source = ClaudeSpeakable.language(of: written)
            let translated = source != nil && source != language
            if translated, let source { Log.write("claude voice: answer translated from \(source) to \(language), not checked") }
            guard !said.isEmpty, translated || ground >= ClaudeSpeakable.groundedFloor else {
                Log.write(String(format: "claude voice: %@ wrote words the reply does not have (%.2f), saying it plain",
                                 model.name, ground))
                var plain = fallback
                plain.task = parsed.task
                return plain
            }
            let opener = ClaudeSpeakable.spokenOpener(parsed.opener)
            let text = opener.isEmpty ? said : opener + " " + said
            Log.write(String(format: "claude voice: %@ answered in %.1fs, %d chars of reply to %d, shift \"%@\"",
                             model.name, Date().timeIntervalSince(started), reply.count + (recap?.count ?? 0),
                             text.count, parsed.tone ?? "none"))
            return Spoken(text: text, tone: base.map { ClaudeSpeakable.instructions(base: $0, shift: parsed.tone) },
                          language: language, task: parsed.task)
        } catch {
            Log.write("claude voice: rewrite failed, saying it plain — \(error.localizedDescription)")
            return fallback
        }
    }

    // MARK: - Which session is talking

    /// The app this session's Claude runs in is in front. In the desktop
    /// app, every session there counts. Without a pid: the window title.
    private func watching(_ id: String) -> Bool {
        guard let session = sessions[id] else { return false }
        guard let host = host(of: id) else { return Self.inFront(project: session.project, agent: session.agent) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == host else { return false }
        // With two windows in one app, only the session's own counts.
        guard let pinned = session.rect ?? session.window.flatMap(SpeakingFrame.frame(of:)) else { return true }
        // By place, not by reference: Ghostty rebuilds its elements as focus moves.
        // A pane is watched only while it has focus; a window, while it is in front.
        if let pane = SpeakingFrame.focusedPane(host: host).flatMap(SpeakingFrame.frame(of:)),
           SpeakingFrame.close(pane, pinned) {
            return true
        }
        guard let focused = SpeakingFrame.focusedWindow(host: host).flatMap(SpeakingFrame.frame(of:)) else { return true }
        return SpeakingFrame.close(focused, pinned)
    }

    private func host(of id: String) -> pid_t? {
        guard let session = sessions[id], session.hostPid == nil, !session.byTitle, let pid = session.pid
        else { return sessions[id]?.hostPid }
        guard session.agent == .codex else {
            sessions[id]?.hostPid = SpeakingFrame.hostApp(of: pid)?.processIdentifier
            return sessions[id]?.hostPid
        }
        switch SpeakingFrame.codexHost(SpeakingFrame.ancestors(of: pid)) {
        case .app(let app): sessions[id]?.hostPid = app
        case .byTitle: sessions[id]?.byTitle = true
        case .none: break
        }
        return sessions[id]?.hostPid
    }

    /// Codex's shared app server hides which terminal a session runs in. Just
    /// after a prompt, a terminal in front whose window names the project is
    /// the one. Else the only terminal window that names it and that no other
    /// such session holds.
    private func findByTitle(_ id: String, prompted: Bool) {
        _ = host(of: id)
        guard let session = sessions[id], session.byTitle else { return }
        if prompted {
            // The session may have moved since: found afresh on each prompt.
            sessions[id]?.hostPid = nil
            sessions[id]?.window = nil
            sessions[id]?.rect = nil
            sessions[id]?.titleMissed = false
        } else if session.hostPid != nil || session.titleMissed {
            return
        }
        if prompted, let front = NSWorkspace.shared.frontmostApplication,
           Self.terminalHosts.contains(front.bundleIdentifier ?? ""),
           SpeakingFrame.focusedWindow(host: front.processIdentifier, naming: session.project) != nil {
            // `pinWindow` pins its focused pane or window next.
            sessions[id]?.hostPid = front.processIdentifier
            return
        }
        let taken = activeSessions.compactMap { $0.key != id && $0.value.byTitle ? $0.value.rect : nil }
        guard let (host, window) = SpeakingFrame.titledWindow(project: session.project, hosts: Self.terminalHosts,
                                                              taken: taken) else {
            sessions[id]?.titleMissed = true
            Log.write("claude voice: no single terminal window names \(session.project), no glow")
            return
        }
        sessions[id]?.hostPid = host
        sessions[id]?.window = window
        sessions[id]?.rect = SpeakingFrame.frame(of: window)
        let app = NSRunningApplication(processIdentifier: host)?.localizedName ?? "pid \(host)"
        Log.write("claude voice: found \(session.project) in \(app) by its window title")
    }

    /// A prompt was just sent from this session, so the focused window of its
    /// host is the session's own.
    private func pinWindow(_ id: String) {
        guard let host = host(of: id), let session = sessions[id],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == host,
              // Found by title: the focused window is the session's only when it names the project too.
              !session.byTitle || SpeakingFrame.focusedWindow(host: host, naming: session.project) != nil,
              let target = SpeakingFrame.focusedPane(host: host) ?? SpeakingFrame.focusedWindow(host: host)
        else { return }
        sessions[id]?.window = target
        sessions[id]?.rect = SpeakingFrame.frame(of: target)
        let at = sessions[id]?.rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
        Log.write("claude voice: pinned \(sessions[id]?.project ?? id) to \(NSRunningApplication(processIdentifier: host)?.localizedName ?? "?") at \(at)")
    }

    private func frameSession(_ id: String?) {
        // A glow still fading out must not write over a window pinned since.
        frame.onRetarget = nil
        guard let id else { return frame.hide() }
        findByTitle(id, prompted: false)
        // Another session speaks now: the old window's glow goes at once.
        guard settings.frame, let session = sessions[id], let host = host(of: id) else {
            return frame.hide(now: true)
        }
        frame.onRetarget = { [weak self] element, rect in
            self?.sessions[id]?.window = element
            self?.sessions[id]?.rect = rect
        }
        let app = NSRunningApplication(processIdentifier: host)?.localizedName ?? "pid \(host)"
        func note(_ how: String, _ rect: CGRect?) {
            let at = rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            Log.write("claude voice: glow for \(session.project) (\(session.agent.rawValue) pid \(session.pid ?? 0)) on \(app), \(how) at \(at)")
        }
        if let window = session.window {
            note("pinned", session.rect)
            return frame.show(window: window, host: host, rect: session.rect)
        }
        guard let guess = SpeakingFrame.guessWindow(host: host, project: session.project) else {
            note("no pin and no safe guess, hidden", nil)
            return frame.hide(now: true)
        }
        sessions[id]?.window = guess
        sessions[id]?.rect = SpeakingFrame.frame(of: guess)
        note("guessed", sessions[id]?.rect)
        frame.show(window: guess, host: host, rect: sessions[id]?.rect)
    }

    /// Once the queue settles: finishing one answer and starting the next is one change.
    private func pillSoon() {
        guard !pillQueued else { return }
        pillQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.pillQueued = false
            self?.updatePill()
        }
    }

    /// Also each second, so "Go to session" follows the window, and the pill comes back
    /// after a dictation took it.
    private func updatePill() {
        let id = queue.playing?.session
        if id == nil || id != pillSession { pillDismissed = nil }
        if let id { pillSession = id }
        let state = VoicePill.of(
            queue, name: id.flatMap(pillName),
            goToSession: id.map { $0 != pillDismissed && host(of: $0) != nil && !watching($0) } ?? false,
            call: call
        )
        if state == nil, case .speaking = pill {
            // Between two answers it stays.
            guard pillLinger == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.pillLinger = nil
                self?.showPill(nil)
            }
            pillLinger = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
            return
        }
        pillLinger?.cancel()
        pillLinger = nil
        showPill(state)
    }

    private func pillName(_ id: String) -> String? {
        guard let session = sessions[id] else { return nil }
        return ClaudeSpeakable.sessionName(
            project: session.project,
            task: session.label ?? ClaudeSpeakable.taskWords(session.task, skipping: session.project))
    }

    private func showPill(_ state: VoicePill?) {
        if state != pill { Log.write("claude voice: pill \(state?.summary ?? "gone")") }
        pill = state
        onVoicePill(state)
        if state == nil {
            pillCheck?.invalidate()
            pillCheck = nil
        } else if pillCheck == nil {
            pillCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updatePill() }
        }
    }

    /// A click on the pill: the session's app comes to the front with its window
    /// raised. Tabs in one window cannot be told apart, as for the glow.
    func goToPillSession() {
        guard let id = pillSession else { return }
        pillDismissed = id
        updatePill()
        guard let host = host(of: id), let app = NSRunningApplication(processIdentifier: host) else { return }
        if let element = sessions[id]?.window, let window = SpeakingFrame.window(of: element) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        let activated = app.activate()
        Log.write("claude voice: went to \(sessions[id]?.project ?? id) in \(app.localizedName ?? "pid \(host)")"
                  + (activated ? "" : ", but the app did not come to the front"))
    }

    private func note(session id: String, agent: CodingAgent, event: [String: Any], pid: pid_t?) {
        let cwd = event["cwd"] as? String ?? ""
        let account = (event["transcript_path"] as? String)?
            .split(separator: "/")
            .first { $0.hasPrefix(".claude-") }
            .map { String($0.dropFirst(".claude-".count)) }
        var session = sessions[id] ?? Session(agent: agent, project: "", account: nil, seen: Date())
        session.project = (cwd as NSString).lastPathComponent
        session.account = account
        session.seen = Date()
        if let pid, pid != session.pid {
            session.hostPid = nil
            session.window = nil
            session.rect = nil
            session.byTitle = false
            session.titleMissed = false
        }
        session.pid = pid ?? session.pid
        let transcript = Self.transcript(event)
        if transcript == nil, let path = (event["transcript_path"] as? String)?.nilIfEmpty {
            skip("transcript " + path, "\(session.project): \(ClaudeSpeakable.basename(path)) is compressed, not read")
        }
        session.transcript = transcript ?? session.transcript
        sessions[id] = session
    }

    private var activeSessions: [String: Session] {
        sessions.filter { Date().timeIntervalSince($0.value.seen) < activeWindow }
    }

    /// Names the session when the line before came from another session
    /// that is still active, or when this one was quiet for two minutes and
    /// its window is not in front.
    private func prefix(for id: String) -> String {
        guard let this = sessions[id], !this.project.isEmpty else { return "" }
        // Still on that pane or window: you know which session this is.
        if watching(id) { return "" }
        let other = lastSpokenSession.flatMap { $0 == id ? nil : activeSessions[$0] } != nil
        let quiet = lastSpokenAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard Self.names(otherSpokeLast: other, quietFor: quiet, inFront: watching(id))
        else { return "" }
        let recent = activeSessions
        let sameProject = recent.values.filter { $0.project == this.project }.count > 1
        let name = sameProject ? [this.project, this.account].compactMap { $0 }.joined(separator: " ") : this.project
        let pick = Self.introductionIndex(after: lastIntroduction, seed: Int(Date().timeIntervalSince1970))
        lastIntroduction = pick
        return Self.introduction(name, pick, language: this.language ?? "en")
    }

    static func names(otherSpokeLast: Bool, quietFor: TimeInterval, inFront: Bool) -> Bool {
        otherSpokeLast || (quietFor >= 120 && !inFront)
    }

    static let introductions = [
        "Update from %@: ", "News from %@: ", "%@ here: ", "Quick one from %@: ", "From %@: ", "On %@: ",
    ]

    /// The same six, in order, per language. A language with none uses English.
    static let localIntroductions: [String: [String]] = [
        "fr": ["Du nouveau sur %@ : ", "Des nouvelles de %@ : ", "Ici %@ : ", "Petit point sur %@ : ",
               "De la part de %@ : ", "Sur %@ : "],
    ]

    static func introduction(_ name: String, _ index: Int, language: String = "en") -> String {
        let list = localIntroductions[language] ?? introductions
        return String(format: list[index % list.count], name)
    }

    /// Any introduction but the one used last.
    static func introductionIndex(after last: Int?, seed: Int) -> Int {
        let count = introductions.count
        var pick = abs(seed) % count
        if pick == last { pick = (pick + 1) % count }
        return pick
    }

    private static let terminalHosts: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2",
        "com.mitchellh.ghostty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
    ]

    /// Whether this project's window is the one in front: a terminal or the
    /// agent's own app is frontmost and its window title names the project. A
    /// host window with no readable title counts as in front.
    static func inFront(project: String, agent: CodingAgent) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              terminalHosts.contains(bundle) || bundle == agent.desktopApp else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return true }
        var title: CFTypeRef?
        // swiftlint:disable:next force_cast
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard let text = title as? String, !text.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(project)
    }

    /// A session keeps its voice. A new one takes the first voice no active
    /// session holds, or shares one when there are more sessions than voices.
    private func voice(for id: String) -> String {
        Self.pick(for: id, from: settings.remoteVoices(model: speaker.remote?.model ?? ""),
                  held: &voices, active: Set(activeSessions.keys))
    }

    private func localVoice(for id: String) -> String? {
        guard !settings.localVoices.isEmpty else { return nil }
        return Self.pick(for: id, from: settings.localVoices, held: &localVoices, active: Set(activeSessions.keys))
    }

    static func pick(for id: String, from pool: [String], held: inout [String: String], active: Set<String>) -> String {
        if let kept = held[id], pool.contains(kept) { return kept }
        let taken = Set(active.compactMap { $0 == id ? nil : held[$0] })
        let chosen = pool.first { !taken.contains($0) } ?? pool[held.count % max(pool.count, 1)]
        held[id] = chosen
        return chosen
    }

    /// Makes the session's reminder from its title, latest summary and request, off the main queue.
    private func remind(_ id: String, request: String, latest: String?, title: String?) {
        sessions[id]?.task = request
        let language = sessions[id]?.language ?? ClaudeSpeakable.language(of: request) ?? "en"
        guard config.llmEnabled, sessions[id]?.reminding != true,
              let prompt = VoicePrompt.reminder.current else { return }
        sessions[id]?.reminding = true
        let named = settings.model.trimmingCharacters(in: .whitespaces)
        let model = config.model(named: named) ?? config.model(for: .general)
        Task.detached {
            let raw = try? await LLM.complete(
                system: prompt.text,
                user: ClaudeSpeakable.reminderInput(request: request, latest: latest, task: title, language: language),
                json: false, maxTokens: 80, config: model
            )
            let said = raw.map { ClaudeSpeakable.capped(ClaudeSpeakable.clean(LLM.stripThinking($0), language: language), limit: 240, count: 2) }
            await MainActor.run { [weak self] in
                self?.sessions[id]?.reminding = false
                guard let said, !said.isEmpty else { return }
                self?.sessions[id]?.reminder = said
                Log.write("claude voice: reminder for \(self?.sessions[id]?.project ?? id): \(said)")
            }
        }
    }

    /// A session first heard without a prompt this run: its reminder comes
    /// from the last request in its transcript, ready for next time.
    private func remindFromTranscript(_ id: String) {
        guard let session = sessions[id], session.reminder == nil, !session.reminding,
              let transcript = session.transcript else { return }
        let agent = session.agent
        Task.detached {
            guard let turn = agent.lastTurn(transcript: transcript),
                  let asked = turn.prompt, !asked.isEmpty else { return }
            let title = agent.title(transcript: transcript)
            await MainActor.run { [weak self] in
                self?.remind(id, request: asked, latest: turn.recap ?? turn.latestText, title: title)
            }
        }
    }

    /// What goes before a line: the session's name when it needs one, and
    /// what the session is about after a while away.
    private func opening(for session: String) -> String {
        let introduced = prefix(for: session)
        var lead = introduced
        let away = sessions[session]?.heard.map { Date().timeIntervalSince($0) } ?? .infinity
        if !introduced.isEmpty, lastSpokenSession != session, away >= 90,
           let reminder = sessions[session]?.reminder {
            lead = introduced + reminder + " "
        }
        if sessions[session]?.reminder == nil { remindFromTranscript(session) }
        sessions[session]?.heard = Date()
        lastSpokenSession = session
        lastSpokenAt = Date()
        return ClaudeSpeakable.spokenRedacted(lead)
    }

    private func style(for session: String, progress: Bool, tone: String?) -> (style: Speaker.Style?, local: String?) {
        // The local voices speak English only.
        let english = (sessions[session]?.language ?? "en") == "en"
        guard speaker.remote != nil, !(progress && settings.progressLocal && english) else {
            return (nil, localVoice(for: session))
        }
        let shift = progress ? "quick, like a passing remark" : nil
        return (Speaker.Style(voice: voice(for: session),
                              tone: tone ?? ClaudeSpeakable.instructions(base: settings.speechTone, shift: shift)), nil)
    }

    private func sayProgress(_ text: String, session: String) {
        let line = opening(for: session) + ClaudeSpeakable.spokenRedacted(text)
        // Whole, so scripts/tone-play.sh can replay it.
        Log.write("claude voice: said: \(line.prefix(800))")
        let voice = style(for: session, progress: true, tone: nil)
        speaker.say(line, style: voice.style, session: session, progress: true, localVoice: voice.local)
    }
}

/// A Unix socket that hands each connection's bytes to `handler`.
final class SocketListener {
    private let fd: Int32
    private let path: String
    private let source: DispatchSourceRead

    init?(path: String, handler: @escaping (Data) -> Void) {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Log.write("claude voice: socket path is too long (\(path.utf8.count) of \(capacity) bytes)")
            return nil
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Log.write("claude voice: could not listen on \(path) — errno \(errno)")
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        self.fd = fd
        self.path = path
        let queue = DispatchQueue(label: "parrotflow.claude-voice")
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                // Accepted sockets inherit O_NONBLOCK on macOS: a read before the hook wrote dropped the event.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var data = Data()
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while data.count < 8 * 1024 * 1024 {
                    let read = Darwin.read(client, &chunk, chunk.count)
                    guard read > 0 else { break }
                    data.append(chunk, count: read)
                }
                close(client)
                if !data.isEmpty { handler(data) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        Log.write("claude voice: listening on \(path)")
    }

    deinit {
        source.cancel()
        unlink(path)
    }
}
