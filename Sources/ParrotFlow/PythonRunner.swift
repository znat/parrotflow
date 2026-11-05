import Darwin
import Foundation

/// Runs the `runner: python` transforms in one Python process the app keeps
/// warm, `built-in/runner/worker.py`, over JSON lines on its stdin and stdout.
///
/// Every way this cannot answer a step returns `.notTaken`, and
/// `CommandRunner` then runs the step as a process, as it always has: no
/// Python, a worker that did not start, a script the worker could not import,
/// a call past the timeout, a worker that died.
final class PythonRunner: @unchecked Sendable {
    static let shared = PythonRunner()

    enum Answer {
        case answered(Result<CommandRunner.Output, CommandRunner.Failure>)
        case notTaken
    }

    /// The built-ins held 17 to 20 MB over 2,000 dictations (14,000 calls), so
    /// these only catch a script of your own that leaks. 10,000 calls is about
    /// 1,600 dictations; growth is counted from the size when it was ready.
    static let restartAfterCalls = 10_000
    static let memoryGrowthCap: UInt64 = 200 << 20
    /// A worker that has not said it is ready by then is stopped, and every
    /// step runs as a process until the app restarts.
    static let startDeadline: TimeInterval = 10

    /// Held for a whole call. A second caller does not queue behind a slow
    /// script: it runs its step as a process.
    private let calling = NSLock()
    private let lock = NSLock()
    private var worker: Worker?
    private var refused: String?
    private var preload: [String] = []
    private var logged: Set<String> = []
    private var lastID = 0

    /// The scripts the app imports at launch.
    static func scripts(in config: Config) -> [String] {
        config.transforms.compactMap { transform in
            guard transform.runner == .python, case .command(let command) = transform.body,
                  let script = CommandRunner.parts(of: command, in: transform.folder).resolved
            else { return nil }
            return script.path
        }
    }

    /// At launch, so the first dictation finds the scripts imported.
    func start(preloading scripts: [String]) {
        lock.lock(); defer { lock.unlock() }
        preload = scripts
        if !scripts.isEmpty, worker == nil, refused == nil { worker = launch() }
    }

    /// The scripts a restart imports. A running worker imports a new one at
    /// its first call.
    func update(preloading scripts: [String]) {
        lock.lock(); defer { lock.unlock() }
        preload = scripts
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        worker?.kill(SIGTERM)
        worker = nil
    }

    func run(
        _ command: String, in folder: TransformFolder, envelope: Data,
        environment: [String: String], seconds: TimeInterval
    ) -> Answer {
        guard ProcessInfo.processInfo.environment["PARROTFLOW_PYTHON_WORKER"] != "off" else {
            return .notTaken
        }
        let (program, arguments, resolved) = CommandRunner.parts(of: command, in: folder)
        guard resolved != nil, envelope.first == UInt8(ascii: "{") else { return .notTaken }
        if let why = Self.unfit(program: program, arguments: arguments) {
            once("fit \(command)", "command: \"\(command)\" runs as a process: \(why)")
            return .notTaken
        }
        guard calling.try() else { return .notTaken }
        defer { calling.unlock() }
        guard let worker = ready(within: seconds) else { return .notTaken }

        lastID += 1
        let id = lastID
        let request = Request(
            id: id, script: program,
            argv: arguments.split(separator: " ").map(String.init),
            env: environment, cwd: folder.workingDirectory.path)
        guard var line = try? JSONEncoder().encode(request) else { return .notTaken }
        line.removeLast()
        line.append(contentsOf: Data(#","envelope":"#.utf8))
        line.append(envelope)
        line.append(contentsOf: Data("}\n".utf8))
        worker.send(line)

        let deadline = Date().addingTimeInterval(seconds)
        while true {
            switch worker.next(until: deadline) {
            case .timedOut:
                replace(worker, "took longer than \(Int(seconds))s on \"\(command)\"")
                return .notTaken
            case .ended:
                replace(worker, "stopped during \"\(command)\"")
                return .notTaken
            case .line(let data):
                guard let head = try? JSONDecoder().decode(Head.self, from: data), head.id == id
                else { continue }
                worker.calls += 1
                defer { recycleIfDue(worker) }
                if let reason = head.fallback {
                    once("fallback \(program) \(reason)",
                         "command: \"\(command)\" runs as a process: the Python worker says it \(reason)")
                    return .notTaken
                }
                if let error = head.error {
                    Log.write("command: \"\(command)\" failed in the Python worker:"
                        + " \(error.prefix(200)); kept the transcript")
                    return .answered(.failure(CommandRunner.Failure(complaint: String(error.prefix(200)))))
                }
                guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
                    Log.write("command: \"\(command)\" declares returns: json but returned"
                        + " \(String(decoding: data.prefix(160), as: UTF8.self)); kept the transcript")
                    return .answered(.failure(CommandRunner.Failure(complaint: "")))
                }
                return .answered(.success(CommandRunner.Output(text: body.result.text, vars: body.result.vars)))
            }
        }
    }

    /// Why this command cannot run in the worker, or nil when it can. The
    /// worker is the interpreter `#!/usr/bin/env python3` finds, and it splits
    /// arguments on spaces only, so anything the shell would read differently
    /// stays with the shell.
    static func unfit(program: String, arguments: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: program) else { return "its script cannot be read" }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 128)) ?? Data(), as: UTF8.self)
        let shebang = head.split(separator: "\n", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard shebang == "#!/usr/bin/env python3" else {
            return "`runner: python` needs the line `#!/usr/bin/env python3` first"
        }
        if arguments.rangeOfCharacter(from: CharacterSet(charactersIn: "\"'\\$`|&;<>()*?[]{}~#\t\n")) != nil {
            return "its arguments need the shell"
        }
        return nil
    }

    // MARK: - The worker's life

    /// The worker, ready for a request, or nil. Started here when nothing
    /// started it, as on the command line.
    private func ready(within seconds: TimeInterval) -> Worker? {
        lock.lock()
        if refused != nil { lock.unlock(); return nil }
        if worker == nil { worker = launch() }
        guard let worker else { lock.unlock(); return nil }
        lock.unlock()
        if worker.ready { return worker }

        let deadline = min(Date().addingTimeInterval(seconds),
                           worker.started.addingTimeInterval(Self.startDeadline))
        switch worker.next(until: deadline) {
        case .line(let data):
            guard (try? JSONDecoder().decode(Head.self, from: data))?.ready == true else {
                refuse(worker, "the Python worker did not start: \(String(decoding: data.prefix(160), as: UTF8.self))")
                return nil
            }
            worker.ready = true
            worker.baseline = worker.residentBytes
            return worker
        case .ended:
            refuse(worker, "the Python worker exited before it was ready")
            return nil
        case .timedOut:
            if Date() >= worker.started.addingTimeInterval(Self.startDeadline) {
                refuse(worker, "the Python worker was not ready in \(Int(Self.startDeadline))s")
            }
            return nil
        }
    }

    /// Called with `lock` held. Nil, and every step a process from then on,
    /// when there is no Python or the worker cannot be launched.
    private func launch() -> Worker? {
        let script = ConfigStore.builtInDirectory.appendingPathComponent("runner/worker.py")
        guard let python = CommandRunner.transformInterpreter() else {
            refused = "no python3 on PATH"
            Log.write("python worker: no python3 on PATH; Python transforms run as processes")
            return nil
        }
        do {
            return try Worker(python: python, script: script.path, preload: preload,
                              environment: CommandRunner.environment(structured: true))
        } catch {
            refused = error.localizedDescription
            Log.write("python worker: could not start \(python) \(script.path):"
                + " \(error.localizedDescription); Python transforms run as processes")
            return nil
        }
    }

    private func refuse(_ old: Worker, _ why: String) {
        old.kill(SIGKILL)
        lock.lock(); defer { lock.unlock() }
        if worker === old { worker = nil }
        refused = why
        Log.write("python worker: \(why); Python transforms run as processes")
    }

    /// Killed by its pid and started again. The step that was running goes
    /// to a process.
    private func replace(_ old: Worker, _ why: String) {
        old.kill(SIGKILL)
        lock.lock(); defer { lock.unlock() }
        Log.write("python worker: \(why); killed pid \(old.pid), restarted, and ran the step as a process")
        if worker === old { worker = launch() }
    }

    private func recycleIfDue(_ current: Worker) {
        let resident = current.residentBytes
        guard current.calls >= Self.restartAfterCalls
            || resident > current.baseline + Self.memoryGrowthCap else { return }
        current.kill(SIGTERM)
        lock.lock(); defer { lock.unlock() }
        Log.write("python worker: restarted after \(current.calls) calls at \(resident >> 20) MB")
        if worker === current { worker = launch() }
    }

    private func once(_ key: String, _ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard logged.insert(key).inserted else { return }
        Log.write(line)
    }

    // MARK: - The protocol

    private struct Request: Encodable {
        let id: Int
        let script: String
        let argv: [String]
        let env: [String: String]
        let cwd: String
    }

    private struct Head: Decodable {
        var id: Int?
        var ready: Bool?
        var error: String?
        var fallback: String?
    }

    private struct Body: Decodable {
        let result: CommandRunner.Reply
    }

    private final class Worker {
        enum Next { case line(Data), timedOut, ended }

        let process = Process()
        let started = Date()
        var ready = false
        var baseline: UInt64 = 0
        var calls = 0
        private let requests: FileHandle
        private let lock = NSLock()
        private var pending = Data()
        private var lines: [Data] = []
        private var finished = false
        private let arrived = DispatchSemaphore(value: 0)

        var pid: pid_t { process.processIdentifier }

        init(python: String, script: String, preload: [String], environment: [String: String]) throws {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script] + preload
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            requests = input.fileHandleForWriting
            _ = fcntl(requests.fileDescriptor, F_SETNOSIGPIPE, 1)

            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil }
                self?.received(chunk)
            }
            var said = Data()
            errors.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                said.append(chunk)
                while let end = said.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: said[said.startIndex..<end], as: UTF8.self)
                    said.removeSubrange(said.startIndex...end)
                    if !line.isEmpty { Log.write("python worker: \(line.prefix(300))") }
                }
            }
            process.terminationHandler = { [weak self] _ in self?.received(Data()) }
            try process.run()
        }

        private func received(_ chunk: Data) {
            lock.lock()
            if chunk.isEmpty {
                finished = true
            } else {
                pending.append(chunk)
                while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(Data(pending[pending.startIndex..<end]))
                    pending.removeSubrange(pending.startIndex...end)
                }
            }
            lock.unlock()
            arrived.signal()
        }

        func next(until deadline: Date) -> Next {
            while true {
                lock.lock()
                if !lines.isEmpty {
                    let line = lines.removeFirst()
                    lock.unlock()
                    return .line(line)
                }
                let over = finished
                lock.unlock()
                if over { return .ended }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 || arrived.wait(timeout: .now() + left) == .timedOut { return .timedOut }
            }
        }

        /// Off this thread: a worker stuck in a script does not read, and a
        /// request past the 64 KB pipe buffer would block here before the
        /// timeout could fire.
        func send(_ line: Data) {
            let requests = requests
            DispatchQueue.global(qos: .userInitiated).async {
                try? requests.write(contentsOf: line)
            }
        }

        func kill(_ signal: Int32) {
            if process.isRunning { Darwin.kill(pid, signal) }
        }

        var residentBytes: UInt64 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
            return info.pti_resident_size
        }
    }
}
