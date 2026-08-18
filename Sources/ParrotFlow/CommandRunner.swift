import Foundation

/// Pipes a transcript through a program of your own.
///
/// The transcript arrives on stdin and comes back on stdout. That is the whole
/// contract, and it is deliberately the smallest one that could work: anything
/// richer — arguments, JSON, an exit protocol — would be a thing to learn
/// before writing three lines of Python.
///
/// It exists because the other two transform bodies can only do what this app
/// already knows how to do. `replace:` cannot change the case of what it
/// captured, so spoken identifiers were going to need a case operator in the
/// substitution engine; the thing after that would have needed something else.
/// A command needs nothing added ever again.
///
/// Everything that can go wrong returns the transcript exactly as it arrived.
/// A dictation tool cannot afford to drop a transcript, and a script you are
/// halfway through writing is an ordinary state to be in.
enum CommandRunner {

    /// A value two threads touch: the reading handler appends on Foundation's
    /// queue while this one waits. A Swift `Data` mutated from both corrupts.
    private final class Locked<Value> {
        private var stored: Value
        private let lock = NSLock()

        init(_ value: Value) { stored = value }

        var value: Value {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func mutate(_ change: (inout Value) -> Void) {
            lock.lock(); defer { lock.unlock() }
            change(&stored)
        }
    }

    /// Long enough for an interpreter to start — `python3` costs 40–60ms cold —
    /// and short enough that a script which hangs cannot hold your dictation.
    /// A stage that takes a second is not a stage anyone wants in a pipeline
    /// that already runs on every transcript.
    static let timeout: TimeInterval = 2

    /// What a command handed back.
    ///
    /// `text` is optional and that is the whole difference between the two
    /// protocols. A bare command's stdout *is* the text, so it always has one. A
    /// `returns: json` command may return only variables — "I looked, I found
    /// three, I changed nothing" — and an absent `text` says that in a way an
    /// echoed copy of the input cannot.
    struct Output: Equatable {
        var text: String?
        var vars: [String: Scope.Value] = [:]
    }

    /// What a structured command is told about the transcript besides the
    /// transcript.
    ///
    /// Read-only from the script's side, and deliberately not the same shape as
    /// what comes back: a command receives the whole accumulated scope and
    /// returns only its own contribution. It has no way to spell "and everything
    /// else, unchanged", so it has no way to drop it. Carrying is the pipeline's
    /// job — a `sed` one-liner could never have echoed a namespace, and a
    /// contract only some bodies can honour is not one.
    struct Context: Encodable {
        let scope: Scope

        /// The bare names go at the top and the namespaced ones nest under
        /// `vars`, so a script reads `ctx["vars"]["numbers"]["count"]` rather
        /// than splitting a dotted string itself. The flat storage inside
        /// `Scope` is an implementation detail of the evaluator, and pushing it
        /// through the interface would make every script a parser.
        ///
        /// Everything comes from the scope and nothing is passed in beside it.
        /// `language` used to be its own parameter, taken from the first
        /// configured language — which is not the detected one, and which was
        /// then encoded *over* the correct value the scope already held, under
        /// the same key. Two sources for one field is how they disagree; there
        /// is now one.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            var nested: [String: [String: Scope.Value]] = [:]
            for path in scope.paths {
                guard let value = scope[path] else { continue }
                guard let dot = path.firstIndex(of: ".") else {
                    try container.encode(value, forKey: Key(path))
                    continue
                }
                let namespace = String(path[path.startIndex..<dot])
                let name = String(path[path.index(after: dot)...])
                nested[namespace, default: [:]][name] = value
            }
            try container.encode(nested, forKey: Key("vars"))
        }

        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ value: String) { stringValue = value }
            init?(stringValue value: String) { stringValue = value }
            init?(intValue: Int) { return nil }
        }
    }

    /// What goes in on stdin when a transform declares `returns: json`.
    ///
    /// `tokens` sits beside `text` rather than inside `ctx` on purpose. `ctx` is
    /// the scope, and the scope is scalars because a `when:` condition compares
    /// scalars. An array of records would drag `Scope.Value` somewhere it does
    /// not need to go.
    private struct Envelope: Encodable {
        let text: String
        let ctx: Context
        /// Recomputed per stage, against the text *this* stage was handed.
        /// Caching it across stages would hand a script offsets into a string
        /// that no longer exists, and at 0.29 ms there is nothing to save.
        let tokens: [Tagger.Token]
        /// Everything the trace has gathered for this dictation so far: the
        /// decoder's own text with its per-word timings and confidences, the
        /// speech segments, and the stages that already ran. Absent outside a
        /// dictation — `--pipeline` has no collector.
        let trace: Trace.Snapshot?
        /// Whether `text` is still the decoder's own, and so whether the word
        /// offsets in `trace.asr.words` line up with it. False as soon as any
        /// stage rewrites. Stated rather than left to be worked out, because
        /// acting on stale offsets fails silently.
        let aligned: Bool
    }

    /// What must come back. Both keys optional, because a script that only
    /// contributes variables and a script that only rewrites text are both
    /// ordinary — and `text: null` is how the first one says so without echoing
    /// a string it never looked at.
    private struct Reply: Decodable {
        var text: String?
        var vars: [String: Scope.Value] = [:]

        enum CodingKeys: String, CodingKey { case text, vars }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            vars = try c.decodeIfPresent([String: Scope.Value].self, forKey: .vars) ?? [:]
        }
    }

    /// stdout, or nil if the program could not run, failed, took too long, or
    /// said nothing. Nil means "keep the transcript".
    ///
    /// `folder` is what a relative path is relative *to*, and what the command
    /// runs in — the transform's own directory, not the process's, which for an
    /// app launched from the Finder is "/" and means nothing.
    static func run(
        _ command: String, on text: String, in folder: TransformFolder?,
        seconds: TimeInterval? = nil
    ) -> String? {
        run(command, on: text, in: folder, seconds: seconds, structured: false, context: nil)?
            .text
    }

    /// The same run, in whichever of the two protocols the transform declared.
    ///
    /// `structured` is read from the config rather than sniffed from the output,
    /// and that is a decision worth defending. The obvious rule — "if stdout
    /// parses as an object with a `text` key, it is structured" — breaks on
    /// exactly the transcript this app is most likely to be handed by somebody
    /// who dictates code: one that *is* a JSON object. Sniffing also means a
    /// script's protocol depends on its output, so a stage silently changes
    /// contract on the one sentence that happens to look like a map.
    ///
    /// Nil still means "keep the transcript", and now also means "and record
    /// that this stage did not work" — the caller turns it into `ok: false`, so
    /// a later condition can tell a stage that failed from a stage that ran and
    /// found nothing.
    static func run(
        _ command: String, on text: String, in folder: TransformFolder?,
        seconds: TimeInterval?, structured: Bool, context: Context?
    ) -> Output? {
        let timeout = seconds ?? Self.timeout
        let folder = folder ?? TransformFolder(configDirectory: ConfigStore.directory, name: "")
        if let complaint = complaint(about: command, in: folder) {
            Log.write("command: \(complaint); kept the transcript")
            return nil
        }

        let process = Process()
        // Through a shell, so a command can carry its arguments and its
        // redirections the way it would in a terminal — `code_identifiers.py --lang
        // python`. The shell is also what resolves a bare name against PATH,
        // which is why the rewriting below only touches a first word that
        // turns out to name a real file next to the config.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand(for: command, in: folder)]
        // The folder, so a script opens `roster.json` as a bare relative path
        // and the whole transform is one directory you can copy.
        process.currentDirectoryURL = folder.workingDirectory
        if structured {
            // So `returns: json` stays the only place the protocol is declared.
            // The script has to know too — it is reading stdin — and the
            // alternative was a flag in the `command:` line that means the same
            // thing as the key above it and can disagree with it.
            //
            // It also keeps a script runnable by hand. `echo "text" | ./x.py`
            // has no variable set, so the script takes the old path, which is
            // what every harness in scripts/ does and what anybody debugging one
            // will type.
            var environment = ProcessInfo.processInfo.environment
            environment["PARROTFLOW_PROTOCOL"] = "json"
            process.environment = environment
        }
        applyInterpreterPath(to: process)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Read while it runs. A script that writes more than a pipe buffer
        // before exiting would otherwise block on the write while we block on
        // the wait below, and neither side would ever move.
        //
        // Two things are being waited on, and conflating them was a bug: EOF on
        // stdout says the output is complete, and termination says the process
        // is gone. A command that closes stdout and keeps running — or hands it
        // to a child and returns — reaches EOF while still alive, and waiting
        // for exit without a deadline after that hangs the pipeline on every
        // transcript from then on.
        let collected = Locked(Data())
        let exited = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.mutate { $0.append(chunk) }
            }
        }
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            Log.write("command: could not run \"\(command)\": \(error.localizedDescription)")
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        // The transcript on its own, or the transcript wrapped in what the
        // pipeline knows about it. An encoding failure falls back to the bare
        // text rather than to nothing: a script that then cannot parse its input
        // fails in its own way and the transcript survives, which is a better
        // outcome than this returning nil for a reason nobody can see.
        var payload = Data(text.utf8)
        if structured, let context {
            let encoder = JSONEncoder()
            // The language the pipeline settled on, not one detected again
            // here. Two sources for one field is how they disagree.
            let language: String? = {
                if case .string(let value)? = context.scope["language"] { return value }
                return nil
            }()
            let snapshot = Trace.current?.snapshot()
            let envelope = Envelope(
                text: text, ctx: context,
                tokens: Tagger.tokens(in: text, language: language),
                trace: snapshot,
                aligned: snapshot?.decodedText == text)
            if let encoded = try? encoder.encode(envelope) {
                payload = encoded
            } else {
                Log.write("command: \"\(command)\" could not be given its context; sent bare text")
            }
        }
        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            stop(process)
            output.fileHandleForReading.readabilityHandler = nil
            Log.write("command: \"\(command)\" took longer than"
                + " \(Int(timeout))s; kept the transcript")
            return nil
        }
        output.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let complaint = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.write(
                "command: \"\(command)\" exited \(process.terminationStatus)"
                + (complaint.isEmpty ? "" : ": \(complaint.prefix(200))")
            )
            return nil
        }

        // Whatever the handler had not been given yet. EOF and exit are not the
        // same instant, and the last chunk is often still in the pipe.
        let rest = output.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { collected.mutate { $0.append(rest) } }

        // Trailing newline only: a script that legitimately indents its output
        // is not this app's business, and `print` adds exactly one newline.
        var result = String(data: collected.value, encoding: .utf8) ?? ""
        if result.hasSuffix("\n") { result.removeLast() }
        guard !result.isEmpty else { return nil }

        guard structured else { return Output(text: result) }

        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(result.utf8)) else {
            // Loud, and then harmless. A transform that declared `returns: json`
            // and printed something else is a script bug rather than a config
            // one, so it cannot be caught by `--check-config` and has to be
            // caught here — but the transcript still comes through untouched,
            // because the alternative is losing a sentence over a stray
            // `print()` somebody left in.
            Log.write(
                "command: \"\(command)\" declares returns: json but printed"
                + " \(result.prefix(120)); kept the transcript"
            )
            return nil
        }
        return Output(text: reply.text, vars: reply.vars)
    }

    /// SIGTERM, then SIGKILL if that was not enough.
    ///
    /// Only the shell is signalled. A command that started something of its own
    /// and returned leaves that behind — killing a whole process tree needs the
    /// child to lead its own process group, which Foundation's `Process` gives
    /// no way to ask for. `shellCommand` narrows the exposure instead: a plain
    /// command is `exec`ed, so the shell *is* the command and there is no tree.
    private static func stop(_ process: Process) {
        process.terminate()
        // A second is generous for a process that has already been asked once.
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// A command split where the program ends and its arguments begin, with
    /// the program made absolute when it names a file beside the config.
    ///
    /// Where to split cannot be decided by looking at the string. A space is
    /// the only separator there is, and it is also an ordinary character in a
    /// path, so `my scripts/rewrite.py --model gemma4:e4b` has three of them
    /// and only one is the boundary. YAML quoting cannot mark it either — the
    /// parser removes the quotes long before this sees them.
    ///
    /// So the file system decides: the longest prefix that names a file is the
    /// program, and the rest is arguments. A first word that names nothing is
    /// left alone for the shell to find on PATH — `sed`, `python3`. That last
    /// case is why `resolved` can be nil on a command that runs perfectly
    /// well, and why the search must not be allowed to turn a bare `sed` into
    /// a complaint.
    static func parts(of command: String, in folder: TransformFolder?)
        -> (program: String, arguments: String, resolved: TransformFolder.Resolved?) {
        // Only when there is a tilde to expand. `expandingTildeInPath` also
        // standardises, and standardising a command is not the same as
        // standardising a path: it drops a trailing slash, so
        // `sed -e s/quick/slow/` reached the shell as `s/quick/slow` and sed
        // refused a substitution it had been handed correctly.
        let expanded = command.hasPrefix("~")
            ? (command as NSString).expandingTildeInPath : command
        let folder = folder ?? TransformFolder(configDirectory: ConfigStore.directory, name: "")

        // Every place the command could be split, longest first. Existing is
        // enough — being executable is not required here, deliberately: a
        // script that is there but not `chmod +x` is the single most likely
        // thing to be wrong, and `complaint` names it as itself rather than
        // leaving the shell to say "command not found".
        //
        // Longest prefix wins over which directory it was found in, and the
        // order matters: `my scripts/rewrite.py --lang python` has three spaces
        // and only one of them is the boundary, so a shorter prefix that
        // happens to exist in the folder must not beat a longer one that
        // exists beside the config.
        var boundaries = [expanded.endIndex]
        boundaries += expanded.indices.filter { expanded[$0] == " " }.reversed()
        for boundary in boundaries {
            let prefix = String(expanded[expanded.startIndex..<boundary])
            guard let found = folder.resolve(prefix) else { continue }
            return (found.path, String(expanded[boundary...]), found)
        }

        guard let first = expanded.split(separator: " ", maxSplits: 1).first else {
            return (expanded, "", nil)
        }
        return (String(first), String(expanded.dropFirst(first.count)), nil)
    }

    /// What the shell is actually given.
    ///
    /// Two things happen to a program that resolved to a file, and neither
    /// applies to a bare `sed` or a pipeline.
    ///
    /// It is **quoted**, because a path is not something the shell should be
    /// reading for syntax. `~/My Configs/parrotflow/code_identifiers.py` was being
    /// split on the space and half of it run as a program.
    ///
    /// And it is **`exec`ed**, which replaces the shell with the program, so
    /// the process this code holds *is* the program. A timeout then kills the
    /// thing that is slow rather than its parent — without it, terminating the
    /// shell left the script running and the next transcript started another.
    static func shellCommand(for command: String, in folder: TransformFolder?) -> String {
        let (program, arguments, resolved) = parts(of: command, in: folder)
        guard resolved != nil else { return program + arguments }
        // A pipeline or a sequence stays the shell's business: `exec` takes one
        // simple command, and the shell is the right thing to be waiting on
        // when there are several.
        let shellSyntax = CharacterSet(charactersIn: "|&;<>()$`\n")
        let prefix = arguments.rangeOfCharacter(from: shellSyntax) == nil ? "exec " : ""
        return prefix + quoted(program) + arguments
    }

    // MARK: - Getting past the version-manager shim

    /// Where the real `python3` lives, resolved once per run of the app.
    ///
    /// A version manager puts a shell script on PATH in place of the
    /// interpreter, and that script re-execs through its own launcher on every
    /// call. Measured on a Mac with pyenv:
    ///
    ///     python3 -c pass  through the shim              301 ms
    ///     python3 -c pass  through the real interpreter    20 ms
    ///     repetitions.py   through the shim              308 ms
    ///     repetitions.py   through the real interpreter    25 ms
    ///
    /// The interpreter reports its own path, so this asks it rather than
    /// guessing at one manager's layout. pyenv, asdf, mise and a plain Homebrew
    /// install all answer the same question.
    private static let interpreterLock = NSLock()
    /// Outer nil means "not asked yet", inner nil means "asked, found nothing".
    nonisolated(unsafe) private static var interpreterDirectory: String??

    private static func realInterpreterDirectory() -> String? {
        // Held across the probe on purpose. A second caller waits for the
        // answer instead of starting a second probe, and the wait is bounded
        // by the deadline in it. It happens once per run of the app.
        interpreterLock.lock()
        defer { interpreterLock.unlock() }
        if let cached = interpreterDirectory { return cached }
        let found = probeInterpreterDirectory()
        interpreterDirectory = .some(found)
        return found
    }

    private static func probeInterpreterDirectory() -> String? {
        let probe = Process()
        // `env`, not a shell. It execs the interpreter in place, so this holds
        // one process and the deadline below signals the interpreter itself. A
        // shell in between can hand stdout to a child that outlives it, and
        // then nothing here knows what to terminate. PATH resolution is the
        // whole point of the probe, and `env` is what does it.
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["python3", "-c", "import sys; print(sys.executable)"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice

        // Read as it arrives, on Foundation's own queue. Reading to EOF from a
        // thread of ours would hold that thread for as long as anything with
        // the write end lives, and the deadline below cannot cut that short.
        let collected = Locked(Data())
        let eof = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                collected.mutate { $0.append(chunk) }
            }
        }
        probe.terminationHandler = { _ in exited.signal() }

        // The probe pays the shim once. Everything after it does not.
        guard (try? probe.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        if exited.wait(timeout: .now() + Self.timeout) == .timedOut {
            // SIGTERM, then SIGKILL, which cannot be ignored. Waiting for the
            // exit is what reaps it: returning from here with the process
            // still running leaves a zombie nothing is watching.
            probe.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(probe.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            Log.write("command: python3 did not say where it is in \(Self.timeout)s; left PATH alone")
            return nil
        }
        // The line was written before the process exited, so this waits on the
        // handoff from Foundation's queue and nothing longer. Whatever has
        // arrived by then is what gets read.
        _ = eof.wait(timeout: .now() + 0.25)
        pipe.fileHandleForReading.readabilityHandler = nil

        let path = (String(data: collected.value, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        Log.write("command: python3 resolves to \(path)")
        return (path as NSString).deletingLastPathComponent
    }

    /// Put the real interpreter ahead of the shim for one subprocess.
    ///
    /// PATH rather than rewriting the command: the scripts say
    /// `#!/usr/bin/env python3`, which is what makes them runnable by hand and
    /// portable to a machine with a different layout. Changing what `env` finds
    /// keeps both.
    private static func applyInterpreterPath(to process: Process) {
        guard let directory = realInterpreterDirectory() else { return }
        var environment = process.environment ?? ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? ""
        guard !existing.hasPrefix(directory + ":"), existing != directory else { return }
        environment["PATH"] = existing.isEmpty ? directory : directory + ":" + existing
        process.environment = environment
    }

    /// A path the shell will read as one word, whatever is in it.
    ///
    /// Single quotes, because they mean "no substitution of any kind" — the one
    /// quoting a directory called `~/My Configs/$stuff` cannot escape from. An
    /// embedded single quote ends the quoting, so it is spelled out.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether the shell will find this name on PATH — `sed`, `python3`.
    ///
    /// Asked so that a command which resolved to no file can be told apart from
    /// a command which named a file that is not there. Both look identical in
    /// the config, and they want opposite responses: one is a one-liner doing
    /// exactly what it says, the other is a transform that will silently do
    /// nothing on every transcript until someone reads the log.
    ///
    /// A name with a slash in it is a path and never a PATH lookup, which is
    /// the shell's rule too.
    static func onPath(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else { return false }
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { directory in
            fm.isExecutableFile(atPath: "\(directory)/\(name)")
        }
    }

    /// What is wrong with this command before it is even run, in words, or nil
    /// if nothing obvious is.
    ///
    /// Only the case that is worth naming: the file is where it should be and
    /// the system will refuse to run it. Everything else — a typo in the name,
    /// an interpreter that is not installed — is the shell's to report, and it
    /// reports those well.
    static func complaint(about command: String, in folder: TransformFolder?) -> String? {
        let (program, _, resolved) = parts(of: command, in: folder)
        let fm = FileManager.default
        guard resolved != nil, fm.fileExists(atPath: program),
              !fm.isExecutableFile(atPath: program) else { return nil }
        return "\(program) is not executable — chmod +x it"
    }
}
