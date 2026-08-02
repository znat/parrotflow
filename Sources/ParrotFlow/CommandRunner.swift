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

    /// stdout, or nil if the program could not run, failed, took too long, or
    /// said nothing. Nil means "keep the transcript".
    ///
    /// `base` is what a relative path is relative *to*: the directory of the
    /// file that declared the transform, so a config carries its scripts beside
    /// it. Not the working directory, which for an app launched from the Finder
    /// is "/" and means nothing.
    static func run(
        _ command: String, on text: String, base: URL?, seconds: TimeInterval? = nil
    ) -> String? {
        let timeout = seconds ?? Self.timeout
        let base = base ?? ConfigStore.directory
        if let complaint = complaint(about: command, base: base) {
            Log.write("command: \(complaint); kept the transcript")
            return nil
        }

        let process = Process()
        // Through a shell, so a command can carry its arguments and its
        // redirections the way it would in a terminal — `identifiers.py --lang
        // python`. The shell is also what resolves a bare name against PATH,
        // which is why the rewriting below only touches a first word that
        // turns out to name a real file next to the config.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand(for: command, base: base)]
        process.currentDirectoryURL = base

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

        input.fileHandleForWriting.write(Data(text.utf8))
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
        return result.isEmpty ? nil : result
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
    /// left alone for the shell to find on PATH — `sed`, `python3`.
    static func parts(of command: String, base: URL?)
        -> (program: String, arguments: String, isPath: Bool) {
        let expanded = (command as NSString).expandingTildeInPath
        let base = base ?? ConfigStore.directory
        let fm = FileManager.default

        func path(for prefix: Substring) -> String {
            prefix.hasPrefix("/")
                ? String(prefix)
                : base.appendingPathComponent(String(prefix)).standardized.path
        }

        // Every place the command could be split, longest first. Existing is
        // enough — being executable is not required here, deliberately: a
        // script that is there but not `chmod +x` is the single most likely
        // thing to be wrong, and `complaint` names it as itself rather than
        // leaving the shell to say "command not found".
        var boundaries = [expanded.endIndex]
        boundaries += expanded.indices.filter { expanded[$0] == " " }.reversed()
        for boundary in boundaries {
            let candidate = path(for: expanded[expanded.startIndex..<boundary])
            guard fm.fileExists(atPath: candidate) else { continue }
            return (candidate, String(expanded[boundary...]), true)
        }

        guard let first = expanded.split(separator: " ", maxSplits: 1).first else {
            return (expanded, "", false)
        }
        return (String(first), String(expanded.dropFirst(first.count)), false)
    }

    /// What the shell is actually given.
    ///
    /// Two things happen to a program that resolved to a file, and neither
    /// applies to a bare `sed` or a pipeline.
    ///
    /// It is **quoted**, because a path is not something the shell should be
    /// reading for syntax. `~/My Configs/parrotflow/identifiers.py` was being
    /// split on the space and half of it run as a program.
    ///
    /// And it is **`exec`ed**, which replaces the shell with the program, so
    /// the process this code holds *is* the program. A timeout then kills the
    /// thing that is slow rather than its parent — without it, terminating the
    /// shell left the script running and the next transcript started another.
    static func shellCommand(for command: String, base: URL?) -> String {
        let (program, arguments, isPath) = parts(of: command, base: base)
        guard isPath else { return program + arguments }
        // A pipeline or a sequence stays the shell's business: `exec` takes one
        // simple command, and the shell is the right thing to be waiting on
        // when there are several.
        let shellSyntax = CharacterSet(charactersIn: "|&;<>()$`\n")
        let prefix = arguments.rangeOfCharacter(from: shellSyntax) == nil ? "exec " : ""
        return prefix + quoted(program) + arguments
    }

    /// A path the shell will read as one word, whatever is in it.
    ///
    /// Single quotes, because they mean "no substitution of any kind" — the one
    /// quoting a directory called `~/My Configs/$stuff` cannot escape from. An
    /// embedded single quote ends the quoting, so it is spelled out.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What is wrong with this command before it is even run, in words, or nil
    /// if nothing obvious is.
    ///
    /// Only the case that is worth naming: the file is where it should be and
    /// the system will refuse to run it. Everything else — a typo in the name,
    /// an interpreter that is not installed — is the shell's to report, and it
    /// reports those well.
    static func complaint(about command: String, base: URL?) -> String? {
        let (program, _, isPath) = parts(of: command, base: base)
        let fm = FileManager.default
        guard isPath, fm.fileExists(atPath: program),
              !fm.isExecutableFile(atPath: program) else { return nil }
        return "\(program) is not executable — chmod +x it"
    }
}
