import AppKit
import Carbon.HIToolbox

/// Escape stops a run, wherever you are. A global monitor sees the key
/// wherever it is pressed and never swallows it.
enum EscapeWatch {
    @MainActor private static var asked = false
    @MainActor private static var watcher: Any?

    @MainActor static func start() {
        asked = false
        guard watcher == nil else { return }
        watcher = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) != ScreenAction.mark
            else { return }
            asked = true
            Log.write("action loop: escape — stopping")
        }
    }

    @MainActor static func stop() {
        if let watcher { NSEvent.removeMonitor(watcher) }
        watcher = nil
        asked = false
    }

    @MainActor static var wasAsked: Bool { asked }

    /// Escape taken by the question panel's tap, which the monitor never sees.
    @MainActor static func press() {
        guard watcher != nil else { return }
        asked = true
        Log.write("action loop: escape on the question — stopping")
    }
}

/// A step a guard would refuse, asked in the question panel. "Yes, go ahead"
/// or a plain yes is yes. "No", a plain no, Escape or 60 s of silence is no.
/// Other words steer: the step is not done, and the words go to the model.
/// `loop.verdict` in the runner is the same rule.
@MainActor enum Confirm {
    static let yes = "Yes, go ahead"

    enum Verdict: Equatable {
        case yes, no
        case redirect(String)
    }

    private static let plainYes: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "yes go ahead", "do it", "oui",
    ]
    private static let plainNo: Set<String> = [
        "no", "nope", "nah", "no thanks", "dont", "do not", "cancel", "stop", "non",
    ]

    nonisolated static func verdict(_ text: String?) -> Verdict {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .no }
        let plain = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text == yes || plainYes.contains(plain) { return .yes }
        if plainNo.contains(plain) { return .no }
        return .redirect(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func ask(
        _ question: String, near: CGRect?, title: String, steps: [String], window: CGRect?
    ) async -> Verdict {
        let answer = await QuestionPanel.shared.ask(
            title: title, steps: steps, question: question, options: [yes, "No"],
            near: near, window: window
        )
        let said = verdict(answer.text)
        switch said {
        case .yes: Log.write("action: allowed — \(question)")
        case .no: Log.write("action: refused — \(question)")
        case .redirect(let words): Log.write("action: redirected — \(question) — \(words.prefix(120))")
        }
        return said
    }
}

/// The action runner, `built-in/recipes/runner.py`: one Python process that
/// decides — the recipes and the loop. It asks for a step and `RecipeSession`
/// does it. The protocol is at the top of `runner.py`.
final class RecipeProcess: @unchecked Sendable {
    static let shared = RecipeProcess()

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var lines = LineBuffer()
    private var complaints = LineBuffer()
    private var startedWith: [String: String] = [:]
    private var starting: Task<Bool, Never>?
    private var busy = false

    static var script: URL {
        ConfigStore.builtInDirectory.appendingPathComponent("recipes/runner.py")
    }

    /// Starts it ahead of the first request, or restarts it when the settings
    /// it was started with have changed.
    func warm(_ config: Config.Actions) async {
        _ = await ensure(Self.environment(config))
    }

    func stop() {
        lock.withLock { terminate() }
    }

    /// One request. Returns the runner's `end` message.
    func run(
        _ request: [String: Any], app: String, config: Config.Actions, say: (String) -> Void
    ) async -> [String: Any] {
        let claimed = lock.withLock { () -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard claimed else {
            say("✗ a recipe is already running")
            return ["end": "failed"]
        }
        defer { lock.withLock { busy = false } }
        guard await ensure(Self.environment(config)) else {
            say("✗ the action runner did not start: \(lock.withLock { self.complaints.last } ?? "no output")")
            return ["end": "failed"]
        }
        let (lines, complaints) = lock.withLock { (self.lines, self.complaints) }

        let gaze = request["gaze"] as? [Int]
        let session = RecipeSession(
            app: app, config: config, title: QuestionPanel.title(request["run"] as? String ?? ""),
            aim: gaze.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        )
        let sent = Date()
        send(request)
        // Quiet for this long means the runner is stuck. A loop of 15 steps
        // with the spotlight on took about a minute, so the limit is on
        // silence rather than on the whole run.
        var heard = sent
        var first = true, watching = false, escaped = false
        var end: [String: Any] = ["end": "failed"]
        defer { ActionSpotlight.dismissSoon() }
        while true {
            if Date().timeIntervalSince(heard) > 120 {
                say("✗ the recipe ran out of time")
                stop()
                break
            }
            let (line, closed) = lines.take()
            guard let line else {
                if closed {
                    say("✗ the recipe failed: \(complaints.last ?? "the runner exited")")
                    stop()
                    break
                }
                // A step is about a dozen round trips; at 2 ms a poll they
                // cost 1.8 ms each.
                try? await Task.sleep(nanoseconds: 200_000)
                continue
            }
            heard = Date()
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                Log.write("recipe: py wrote a line that is not JSON: \(line.prefix(120))")
                continue
            }
            if message["end"] is String {
                end = message
                break
            }
            guard let verb = message["do"] as? String else { continue }
            if verb == "progress" {
                send(await session.handle(verb, message, say: say))
                continue
            }
            if first, verb != "say", verb != "log" {
                first = false
                Log.write("recipe: first step, \(verb), after \(Int(Date().timeIntervalSince(sent) * 1000)) ms")
            }
            if watching, !escaped, await MainActor.run(body: { EscapeWatch.wasAsked }) {
                escaped = true
                say("✗ Escape — stopped")
            }
            if escaped {
                send(["error": "escape", "said": true])
                continue
            }
            let reply = await session.handle(verb, message, say: say)
            send(reply)
            // A step that waited for the user was not the runner being quiet.
            if reply["paused_ms"] != nil { heard = Date() }
            if verb == "begin" || verb == "watch", !watching {
                watching = true
                await MainActor.run { EscapeWatch.start() }
            }
        }
        if session.showsPanel {
            let outcome = Self.outcome(of: end)
            await MainActor.run { QuestionPanel.shared.end(outcome: outcome) }
        } else {
            await MainActor.run { QuestionPanel.shared.close() }
        }
        if watching { await MainActor.run { EscapeWatch.stop() } }
        return end
    }

    /// How a run ended, for the panel, when the runner did not say.
    private static func outcome(of end: [String: Any]) -> String {
        if let loop = end["loop"] as? [String: Any], let stopped = loop["stopped"] as? String,
           !stopped.isEmpty {
            return stopped
        }
        switch end["end"] as? String {
        case "done": return "Done"
        case "ready": return "Ready — dictate"
        case "planned": return "Planned only"
        case "stopped": return "Stopped"
        default: return "Failed"
        }
    }

    // MARK: - The process

    /// The key goes in the environment, never on the command line.
    private static func environment(_ config: Config.Actions) -> [String: String] {
        var env = [
            "PARROTFLOW_JEV_KEY_SOURCE": config.decider.apiKey.described,
            "PARROTFLOW_JEV_URL": config.decider.url.absoluteString,
            "PARROTFLOW_JEV_MODEL": config.decider.model,
            "PARROTFLOW_JEV_TIMEOUT": String(config.decider.timeoutSeconds),
            "PARROTFLOW_RECIPES_USER": ConfigStore.directory
                .appendingPathComponent("recipes", isDirectory: true).path,
            "PARROTFLOW_APP_NOTES": ConfigStore.directory
                .appendingPathComponent("apps", isDirectory: true).path,
        ]
        if let key = config.decider.apiKey.resolve() { env["PARROTFLOW_JEV_KEY"] = key }
        if let planner = config.planner {
            env["PARROTFLOW_PLANNER_MODEL"] = planner.model
            env["PARROTFLOW_PLANNER_URL"] = planner.endpoint
            env["PARROTFLOW_PLANNER_REASONING"] = planner.reasoning
            env["PARROTFLOW_PLANNER_TIMEOUT"] = String(planner.timeoutSeconds)
            env["PARROTFLOW_PLANNER_LOOP"] = planner.loop
            env["PARROTFLOW_PLANNER_TRACE"] = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/" + AppVariant.logFileName
                    .replacingOccurrences(of: ".log", with: "-agent.jsonl")).path
            env["PARROTFLOW_PLANNER_KEY_SOURCE"] = planner.apiKey.described
            if let key = planner.apiKey.resolve() { env["PARROTFLOW_PLANNER_KEY"] = key }
        }
        if config.record { env["PARROTFLOW_RUNS"] = runsFolder.path }
        env["PARROTFLOW_GROUND"] = config.ground
        env["PARROTFLOW_SUPPORT"] = AppVariant.supportDirectory.path
        return env
    }

    /// `~/Library/Logs/ParrotFlow-Dev-runs`, or `ParrotFlow-runs` for release.
    static var runsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Logs/" + AppVariant.logFileName.replacingOccurrences(of: ".log", with: "-runs"),
            isDirectory: true)
    }

    private func ensure(_ env: [String: String]) async -> Bool {
        let task = lock.withLock { () -> Task<Bool, Never> in
            if let starting { return starting }
            if let process, process.isRunning, startedWith == env { return Task { true } }
            let task = Task { await self.start(env) }
            starting = task
            return task
        }
        let up = await task.value
        lock.withLock { if starting == task { starting = nil } }
        return up
    }

    private func start(_ env: [String: String]) async -> Bool {
        let begun = Date()
        let interpreter = CommandRunner.transformInterpreter() ?? "/usr/bin/python3"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = ["-u", Self.script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONIOENCODING"] = "utf-8"
        environment.merge(env) { _, new in new }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A runner that has exited must not take the app down with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let lines = LineBuffer()
        let complaints = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            lines.feed(chunk)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            complaints.feed(chunk)
            for line in complaints.takeAll() {
                Log.write("recipe: py: \(line)")
                complaints.remember(line)
            }
        }
        process.terminationHandler = { ended in
            Log.write("recipe: the runner exited (\(ended.terminationStatus))")
        }

        lock.withLock {
            terminate()
            self.lines = lines
            self.complaints = complaints
        }
        let spawned = Date()
        do {
            try process.run()
        } catch {
            Log.write("recipe: could not start \(Self.script.path): \(error.localizedDescription)")
            return false
        }
        lock.withLock {
            self.process = process
            self.input = input.fileHandleForWriting
            self.startedWith = env
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let (line, closed) = lines.take()
            if let line {
                if line.contains("\"up\"") {
                    let total = Int(Date().timeIntervalSince(begun) * 1000)
                    let own = Int(Date().timeIntervalSince(spawned) * 1000)
                    Log.write("recipe: runner up in \(total) ms, \(own) ms of it after the spawn, pid \(process.processIdentifier)")
                    return true
                }
                continue
            }
            if closed { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        Log.write("recipe: the runner did not say it was up: \(complaints.last ?? "no output")")
        stop()
        return false
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object),
              let input = lock.withLock({ self.input }) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    /// Called with the lock held.
    private func terminate() {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        startedWith = [:]
    }
}

/// Lines from a pipe, as they complete.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var ready: [String] = []
    private var closed = false
    private var lastLine: String?

    func feed(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty else {
            closed = true
            if !pending.isEmpty { ready.append(String(decoding: pending, as: UTF8.self)) }
            pending = Data()
            return
        }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            ready.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
    }

    func take() -> (String?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if !ready.isEmpty { return (ready.removeFirst(), false) }
        return (nil, closed)
    }

    func takeAll() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let all = ready
        ready = []
        return all
    }

    func remember(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastLine = line }
    }

    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastLine
    }
}

/// What one run has seen, and the steps it asks for.
private final class RecipeSession {
    /// The app the run acts on. The loop sets it with its first read.
    var app: String
    let config: Config.Actions
    private var never: [String]
    /// The request, as the question panel titles it.
    private let title: String
    /// The steps done so far, as the runner last sent them.
    private var shown: [String] = []
    /// Where the user looked at the request, in screen points.
    private let aim: CGPoint?
    /// The run panel is up for this run.
    private(set) var showsPanel = false

    private var items: [Int: ScreenTargets.Item] = [:]
    /// Rows from a list outside the window, and the field they hang from.
    /// Outlook fills that list twice, local then server, so a row is found
    /// again by name before it is clicked.
    private var outsideRows: [Int: CGRect] = [:]
    private var marks: [Int: (snapshot: ScreenTargets.Snapshot, windows: [CGRect], at: CGPoint)] = [:]
    private var snapshots: [Int: ScreenTargets.Snapshot] = [:]
    /// The app's windows and pop-ups at the run's first read. What opens
    /// after is read with the front window; what was there is not.
    private var parts: ScreenTargets.Parts?
    private var nextID = 1

    init(app: String, config: Config.Actions, title: String, aim: CGPoint?) {
        self.app = app
        self.config = config
        self.title = title
        self.aim = aim
        never = config.neverPress
    }

    // `press` and `scroll` are not here: an accessibility press needs no
    // focus, and a wheel event goes to the pane under the point.
    static let touchesScreen: Set<String> = [
        "key", "type", "paste", "click", "click_at", "right_click", "hover", "drag", "ready",
        "select", "show_menu",
    ]

    /// While the user types to the run, a step that touches the screen waits.
    /// Its reply then says for how long, in `paused_ms`.
    func handle(_ verb: String, _ r: [String: Any], say: (String) -> Void) async -> [String: Any] {
        guard Self.touchesScreen.contains(verb) else { return await perform(verb, r, say: say) }
        let began = Date()
        var waited = false
        while await MainActor.run(body: { QuestionPanel.shared.holdsRun }) {
            if !waited {
                waited = true
                Log.write("action: \(verb) waits — the user is typing to the run")
            }
            if await MainActor.run(body: { EscapeWatch.wasAsked }) {
                return ["error": "escape", "said": true]
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard waited else { return await perform(verb, r, say: say) }
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        Log.write("action: \(verb) goes on after \(ms) ms")
        var reply = await perform(verb, r, say: say)
        reply["paused_ms"] = ms
        return reply
    }

    private func perform(_ verb: String, _ r: [String: Any], say: (String) -> Void) async -> [String: Any] {
        if let steps = r["shown"] as? [String] { shown = steps }
        // Keys and clicks go to whatever is in front. Seen 09-22: Slack was in
        // front mid-run and the letters meant for Outlook's To field never
        // arrived there.
        if Self.touchesScreen.contains(verb),
           let front = NSWorkspace.shared.frontmostApplication?.localizedName, front != app {
            let line = "\(front) is in front, not \(app) — stopping before \(verb)"
            say("✗ \(line)")
            return ["error": "not in front", "said": true, "text": line]
        }
        switch verb {
        case "progress":
            let first = !showsPanel
            showsPanel = true
            // The loop learns the app at its first read; the app in front is the one looked at.
            let owner = app.isEmpty ? NSWorkspace.shared.frontmostApplication?.localizedName ?? "" : app
            let window = first ? ScreenTargets.windowFrames(ofApp: owner).first : nil
            await MainActor.run {
                let panel = QuestionPanel.shared
                if first {
                    panel.begin(title: r["title"] as? String ?? title, window: window, aim: aim)
                }
                panel.runApp = owner
                panel.update(r)
            }
            return ["ok": true]

        case "steer":
            let messages = await MainActor.run { QuestionPanel.shared.takeSteers() }
            return ["messages": messages]

        case "begin":
            let allowed = (r["allows"] as? [String] ?? []).map { $0.lowercased() }
            never = config.neverPress.filter { phrase in
                !allowed.contains { phrase.lowercased().contains($0) }
            }
            guard let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == app
            }) else {
                say("✗ \(app) is not running")
                return ["error": "not running", "said": true]
            }
            running.activate()
            try? await Task.sleep(nanoseconds: 400_000_000)
            return ["ok": true]

        case "key":
            guard let keys = r["keys"] as? String, let (code, flags) = Self.key(keys) else {
                return ["error": "unknown key \(r["keys"] ?? "")"]
            }
            // `send: false` held because the loop knew when it was sending.
            // A step only says "Return", so the caret decides. A lookup field
            // (Slack's search, a To field) still takes it.
            if !config.send, code == CGKeyCode(kVK_Return),
               config.returnSends.contains(ScreenTargets.bundle(ofApp: app) ?? ""),
               ScreenTargets.focusIsMessageBox(ofApp: app) {
                switch await confirm("Press Return in the message box? It may send.",
                                     near: ScreenTargets.focusFrame(ofApp: app)) {
                case .yes: break
                case .redirect(let words): return ["error": "redirected", "text": words]
                case .no:
                    let line = "Won't press Return in the message box — send is off"
                    say("✗ \(line)")
                    Log.write("action: refused \(keys) — the caret is in a message box and send is off")
                    return ["error": "send is off", "said": true, "text": line]
                }
            }
            ScreenAction.press(code, flags: flags)
            await pause(r["wait"])
            return ["ok": true]

        case "type":
            ScreenAction.keystrokes(r["text"] as? String ?? "")
            return ["ok": true]

        case "paste":
            ScreenAction.type(r["text"] as? String ?? "")
            return ["ok": true]

        case "wait":
            await pause(r["ms"])
            return ["ok": true]

        case "lookup_field":
            guard ScreenTargets.caretIsInLookupField(ofApp: app) else {
                say("  focus: \(ScreenTargets.focusDescription(ofApp: app))")
                return ["item": NSNull()]
            }
            let caret = ScreenTargets.focus(ofApp: app)
            let fields = ((try? ScreenTargets.snapshot(ofApp: app, at: .zero))?.items ?? [])
                .filter { $0.looksThingsUp }
            // Outlook's Search box is a lookup field too; the caret says which.
            if let caret, let nearest = fields.min(by: {
                hypot(Double($0.x) - caret.x, Double($0.y) - caret.y)
                    < hypot(Double($1.x) - caret.x, Double($1.y) - caret.y)
            }) {
                return ["item": register(nearest)]
            }
            guard let caret else { return ["item": NSNull()] }
            return ["item": register(ScreenTargets.Item(
                kind: ScreenTargets.Kind.text, role: "AXTextField", name: "", value: "", cm: 0,
                x: Int(caret.x), y: Int(caret.y), w: 0, h: 0, actions: []
            ))]

        case "find":
            let role = r["role"] as? String
            let name = (r["name"] as? String)?.lowercased()
            let kind = r["kind"] as? String
            let found = ((try? ScreenTargets.snapshot(ofApp: app, at: .zero))?.items ?? []).filter {
                (role == nil || $0.role == role)
                    && (kind == nil || $0.kind == kind)
                    && (name == nil || $0.name.lowercased().contains(name!))
            }
            return ["items": found.map(register)]

        case "frames":
            let role = r["role"] as? String ?? ""
            let boxes = ScreenTargets.elements(ofApp: app, role: role)
            return ["items": boxes.map { register(Self.item(role: role, box: $0)) }]

        case "pressable_at":
            let point = Self.point(r["x"], r["y"])
            guard let box = ScreenTargets.pressableFrame(at: point) else { return ["item": NSNull()] }
            return ["item": register(Self.item(role: "AXButton", box: box))]

        case "mark":
            let at = (r["at"] as? [Double]).map { CGPoint(x: $0[0], y: $0[1]) } ?? .zero
            guard let snapshot = try? ScreenTargets.snapshot(ofApp: app, at: at) else {
                return ["error": "could not read \(app)"]
            }
            let id = nextID
            nextID += 1
            marks[id] = (snapshot, ScreenTargets.windowFrames(ofApp: app), at)
            return ["mark": id]

        case "rows":
            guard let mark = marks[r["since"] as? Int ?? 0] else { return ["error": "no such mark"] }
            let field = items[r["under"] as? Int ?? 0]
            let outside = r["outside_window"] as? Bool ?? false
            let (rows, waited) = await Recipes.list(
                in: app, since: mark.snapshot, windows: mark.windows, under: field,
                deep: outside, ms: r["ms"] as? Int ?? 3000
            )
            if rows.isEmpty {
                say("  focus: \(ScreenTargets.focusDescription(ofApp: app))")
                if let field {
                    for line in ScreenTargets.findList(ofApp: app, under: Self.box(field), matching: "@") {
                        say("  \(line)")
                    }
                }
            }
            return ["waited": waited, "items": rows.map { row in
                let entry = register(row)
                if outside, let field, let id = entry["id"] as? Int { outsideRows[id] = Self.box(field) }
                return entry
            }]

        case "appeared":
            guard let mark = marks[r["since"] as? Int ?? 0] else { return ["error": "no such mark"] }
            let (found, waited) = await appeared(
                since: mark, ms: r["ms"] as? Int ?? 2000,
                settle: r["settle"] as? Bool ?? false, windows: r["windows"] as? Bool ?? false
            )
            return ["waited": waited, "items": found.map(register)]

        case "snapshot":
            let at = (r["at"] as? [NSNumber]).map {
                CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue)
            } ?? .zero
            let snapshot: ScreenTargets.Snapshot
            do {
                if let named = r["app"] as? String, !named.isEmpty {
                    snapshot = try ScreenTargets.snapshot(ofApp: named, at: at, since: &parts)
                } else {
                    snapshot = try ScreenTargets.snapshot(
                        at: at, ignoring: Set(config.ignoreApps), since: &parts
                    )
                }
            } catch {
                return ["error": error.localizedDescription]
            }
            app = snapshot.app
            let id = nextID
            nextID += 1
            snapshots[id] = snapshot
            var reply: [String: Any] = [
                "snapshot": Recipes.encode(snapshot, id: id, items: snapshot.items.map(register)),
            ]
            let window = CGRect(x: snapshot.frame.x, y: snapshot.frame.y,
                                width: snapshot.frame.w, height: snapshot.frame.h)
            let see = config.see && r["see"] as? Bool == true
            await ScreenText.window(window, shot: r["shot"] as? String, see: see, into: &reply)
            if let ms = reply["seen_ms"] as? Int, ms > 80 {
                Log.write("action: reading the window's text took \(ms) ms"
                          + " (\(Int(window.width))×\(Int(window.height)) pt)")
            }
            if let error = reply["seen_error"] as? String {
                Log.write("action: could not read the window's text — \(error)")
            }
            return reply

        case "ask":
            let answer = await QuestionPanel.shared.ask(
                title: title, steps: shown, question: r["question"] as? String ?? "",
                options: r["options"] as? [String] ?? [], near: Self.frame(r["near"]),
                window: ScreenTargets.windowFrames(ofApp: app).first
            )
            return answer.reply

        case "press":
            guard let target = items[r["id"] as? Int ?? 0] else { return ["error": "no such element"] }
            if let refusal = await refuse(target, say: say) { return refusal }
            if target.origin != nil {
                // As in `click`: the row click in Outlook's list missed 2 of 2
                // without this read and took 3 of 3 with it.
                Log.write("action: pressing in the \(target.origin ?? "") on \u{201c}\(ScreenTargets.name(at: target.point))\u{201d}")
            }
            let under = config.record ? ScreenTargets.hit(at: target.point) : nil
            let pressed = ScreenAction.pressWithoutPointer(
                target, clickRatherThanPress: r["click"] as? Bool ?? false)
            if !pressed {
                Log.write("action: clicking at \(target.x),\(target.y)")
                ScreenAction.click(at: target.point)
            }
            return ["ok": true, "pressed": pressed, "at": [target.x, target.y], "under": under ?? NSNull()]

        case "scroll":
            ScreenAction.wheel(
                at: Self.point(r["x"], r["y"]), down: r["down"] as? Bool ?? true,
                turns: r["turns"] as? Int ?? 6
            )
            return ["ok": true]

        case "select":
            guard let target = items[r["id"] as? Int ?? 0] else { return ["error": "no such element"] }
            if let refusal = await refuse(target, say: say) { return refusal }
            ScreenAction.selectText(of: target)
            return ["ok": true]

        case "show_menu":
            // The element's own menu first: nothing moves, so nothing drawn by
            // the pointer closes. A right-click is the fallback, for a web
            // page that answers the action and does nothing with it.
            if let id = r["id"] as? Int {
                guard let target = items[id] else { return ["error": "no such element"] }
                if let refusal = await refuse(target, say: say) { return refusal }
                let spot = target.point
                if ScreenTargets.showMenu(at: spot) {
                    Log.write("action: opened the menu at \(Int(spot.x)),\(Int(spot.y)) — the pointer did not move")
                } else {
                    Log.write("action: right-clicking at \(Int(spot.x)),\(Int(spot.y)) — the menu action was refused")
                    ScreenAction.rightClick(at: spot)
                }
            } else {
                let spot = Self.point(r["x"], r["y"])
                Log.write("action: right-clicking at \(Int(spot.x)),\(Int(spot.y)) — no target, so where you looked")
                ScreenAction.rightClick(at: spot)
            }
            return ["ok": true]

        case "front":
            // A chord needs the app in front; a press does not.
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == app
            }), !running.isActive {
                running.activate()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            return ["ok": true]

        case "focus":
            let named = r["app"] as? String ?? app
            let point = ScreenTargets.focus(ofApp: named)
            return ["point": point.map { [$0.x, $0.y] } as Any? ?? NSNull(),
                    "described": ScreenTargets.focusDescription(ofApp: named),
                    "role": ScreenTargets.focusRole(ofApp: named) as Any? ?? NSNull()]

        case "ready_for_words":
            let box = ScreenTargets.readyForWords(ofApp: r["app"] as? String ?? app)
            return ["box": box as Any? ?? NSNull()]

        case "spotlight":
            guard let snapshot = snapshots[r["snapshot"] as? Int ?? 0] else { return ["error": "no such snapshot"] }
            let offers = (r["offers"] as? [Int] ?? []).compactMap { items[$0] }
            let chosen = (r["chosen"] as? Int).flatMap { items[$0] }
            let aim = (r["aim"] as? [NSNumber]).map {
                CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue)
            } ?? .zero
            let seconds = (r["seconds"] as? NSNumber)?.doubleValue ?? 2.5
            await MainActor.run {
                _ = ActionSpotlight.flash(offers: offers, aim: aim, in: snapshot, chosen: chosen, seconds: seconds)
            }
            return ["ok": true]

        case "spotlight_dismiss":
            await MainActor.run { ActionSpotlight.dismiss() }
            return ["ok": true]

        case "watch":
            return ["ok": true]

        case "click":
            let id = r["id"] as? Int ?? 0
            guard var target = items[id] else { return ["error": "no such element"] }
            if let word = ScreenAction.refuses(target.name, never) {
                say("✗ refused to click \u{201c}\(target.name.prefix(30))\u{201d}: \u{201c}\(word)\u{201d} is on never_press")
                return ["error": "refused", "said": true]
            }
            if let field = outsideRows[id] {
                if let same = ScreenTargets.listRows(ofApp: app, under: field).first(where: { $0.name == target.name }) {
                    if same.y != target.y { say("           the row moved from y \(target.y) to \(same.y)") }
                    target = same
                } else {
                    say("           the row is gone from the list; clicking where it was")
                }
            }
            // Measured 09-22 in Outlook: without this read the row click
            // missed 2 of 2, with it the click took 3 of 3. Why is not known.
            let hit = config.record ? ScreenTargets.hit(at: target.point) : nil
            let under = hit?["name"] as? String ?? ScreenTargets.name(at: target.point)
            Log.write("recipe: click at \(target.x),\(target.y) on \u{201c}\(under)\u{201d}")
            ScreenAction.click(at: target.point)
            return ["ok": true, "at": [target.x, target.y], "under": hit ?? NSNull()]

        case "look":
            guard let region = Self.frame(r), region.width >= 1, region.height >= 1 else {
                return ["error": "look needs x, y, w and h"]
            }
            let start = Date()
            do {
                let lines = try await ScreenText.read(region)
                Log.write("action: looked at \(Int(region.minX)),\(Int(region.minY)) \(Int(region.width))×\(Int(region.height))"
                          + " — \(lines.count) lines in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                return ["lines": lines.map(\.encoded)]
            } catch {
                Log.write("action: could not look — \(error.localizedDescription)")
                return ["error": error.localizedDescription]
            }

        case "click_at", "right_click", "hover":
            let point = Self.point(r["x"], r["y"])
            if verb != "hover" {
                // A line `look` saw is checked by its text too: the tree may
                // not hold it.
                let seen = r["name"] as? String ?? ""
                let name = ScreenAction.refuses(seen, never) != nil ? seen : ScreenTargets.name(at: point)
                if let word = ScreenAction.refuses(name, never) {
                    say("✗ refused to click \u{201c}\(name.prefix(30))\u{201d}: \u{201c}\(word)\u{201d} is on never_press")
                    return ["error": "refused", "said": true]
                }
            }
            let under = config.record && verb != "hover" ? ScreenTargets.hit(at: point) : nil
            switch verb {
            case "click_at": ScreenAction.click(at: point)
            case "right_click": ScreenAction.rightClick(at: point)
            default: ScreenAction.hover(at: point)
            }
            return ["ok": true, "under": under ?? NSNull()]

        case "drag":
            guard let start = r["start"] as? [Double], let end = r["end"] as? [Double],
                  start.count == 2, end.count == 2 else { return ["error": "drag needs start and end"] }
            ScreenAction.drag(from: CGPoint(x: start[0], y: start[1]), to: CGPoint(x: end[0], y: end[1]))
            return ["ok": true]

        case "say":
            say(r["text"] as? String ?? "")
            return ["ok": true]

        case "log":
            let text = r["text"] as? String ?? ""
            Log.write(r["plain"] as? Bool == true ? text : "recipe: \(text)")
            return ["ok": true]

        case "ready":
            guard let target = items[r["id"] as? Int ?? 0] else { return ["error": "no such element"] }
            ScreenAction.click(at: target.point)
            let what = target.name.isEmpty ? "the field" : "the \(target.name.lowercased())"
            say("step       caret in \(what) — ready to dictate")
            return ["ok": true]

        default:
            return ["error": "unknown step \(verb)"]
        }
    }

    /// What can be clicked now that was not there at the mark. With `settle`,
    /// waits until the count stops growing: search results arrive in batches.
    private func appeared(
        since mark: (snapshot: ScreenTargets.Snapshot, windows: [CGRect], at: CGPoint),
        ms: Int, settle: Bool, windows: Bool
    ) async -> ([ScreenTargets.Item], Int) {
        let start = Date()
        var found: [ScreenTargets.Item] = []
        var last = -1
        var waited = 0
        while Date().timeIntervalSince(start) * 1000 < Double(ms) {
            try? await Task.sleep(nanoseconds: settle ? 400_000_000 : 250_000_000)
            if windows {
                found = ScreenTargets.newWindows(ofApp: app, besides: mark.windows).filter { !$0.name.isEmpty }
            }
            if found.isEmpty, let now = try? ScreenTargets.snapshot(ofApp: app, at: mark.at) {
                found = Recipes.appeared(from: mark.snapshot, to: now).filter {
                    $0.kind == ScreenTargets.Kind.click && !$0.name.isEmpty
                }
            }
            waited = Int(Date().timeIntervalSince(start) * 1000)
            if settle {
                if !found.isEmpty && found.count == last { break }
                last = found.count
            } else if !found.isEmpty {
                break
            }
        }
        return (found, waited)
    }

    private func pause(_ value: Any?) async {
        let ms = min(max(value as? Int ?? 0, 0), 10_000)
        if ms > 0 { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
    }

    private func register(_ item: ScreenTargets.Item) -> [String: Any] {
        let id = nextID
        nextID += 1
        items[id] = item
        return Recipes.encode(item, id: id, never: never)
    }

    /// `never_press`, at the moment of acting.
    private func refuse(_ target: ScreenTargets.Item, say: (String) -> Void) async -> [String: Any]? {
        guard let word = ScreenAction.refuses(target.name, never) else { return nil }
        switch await confirm("Press \u{201c}\(target.name.prefix(30))\u{201d}? It matches never_press \u{201c}\(word)\u{201d}.",
                             near: Self.box(target)) {
        case .yes: return nil
        case .redirect(let words): return ["error": "redirected", "text": words]
        case .no: break
        }
        Log.write("action: refused — \"\(target.name.prefix(40))\" matches \"\(word)\"")
        say("✗ refused to press \u{201c}\(target.name.prefix(30))\u{201d}: \u{201c}\(word)\u{201d} is on never_press")
        return ["error": "refused", "said": true,
                "text": "Won't press \"\(target.name.prefix(30))\" — that is yours to do"]
    }

    private func confirm(_ question: String, near: CGRect?) async -> Confirm.Verdict {
        await Confirm.ask(
            question, near: near, title: title, steps: shown,
            window: ScreenTargets.windowFrames(ofApp: app).first
        )
    }

    /// `{x, y, w, h}` with x, y the centre, as items carry it.
    private static func frame(_ value: Any?) -> CGRect? {
        guard let near = value as? [String: Any],
              let x = (near["x"] as? NSNumber)?.doubleValue, let y = (near["y"] as? NSNumber)?.doubleValue,
              let w = (near["w"] as? NSNumber)?.doubleValue, let h = (near["h"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
    }

    private static func item(role: String, box: CGRect) -> ScreenTargets.Item {
        ScreenTargets.Item(
            kind: ScreenTargets.Kind.other, role: role, name: "", value: "", cm: 0,
            x: Int(box.midX), y: Int(box.midY), w: Int(box.width), h: Int(box.height), actions: []
        )
    }

    private static func box(_ item: ScreenTargets.Item) -> CGRect {
        CGRect(x: item.x - item.w / 2, y: item.y - item.h / 2, width: item.w, height: item.h)
    }

    private static func point(_ x: Any?, _ y: Any?) -> CGPoint {
        CGPoint(x: (x as? NSNumber)?.doubleValue ?? 0, y: (y as? NSNumber)?.doubleValue ?? 0)
    }

    /// "cmd+n", "return", "shift+tab".
    private static func key(_ spec: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: code = keyCodes[part]
            }
        }
        return code.map { ($0, flags) }
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var codes: [String: CGKeyCode] = [
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
            "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
            "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
            "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
            "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
            "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ]
        for (letter, code) in letters { codes[letter] = CGKeyCode(code) }
        let others: [(String, Int)] = [
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
            ("8", kVK_ANSI_8), ("9", kVK_ANSI_9), ("[", kVK_ANSI_LeftBracket),
            ("]", kVK_ANSI_RightBracket), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period),
            ("/", kVK_ANSI_Slash), (";", kVK_ANSI_Semicolon), ("-", kVK_ANSI_Minus),
            ("=", kVK_ANSI_Equal), ("'", kVK_ANSI_Quote), ("`", kVK_ANSI_Grave),
        ]
        for (key, code) in others { codes[key] = CGKeyCode(code) }
        return codes
    }()
}
