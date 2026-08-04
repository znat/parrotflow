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
    /// `folder` is what a relative path is relative *to*, and it is two places:
    /// `transforms/<name>/` first, then the config directory itself, so a
    /// script written before folders existed keeps running from where it is.
    /// It is also the working directory — the folder's, not the process's,
    /// which for an app launched from the Finder is "/" and means nothing.
    static func run(
        _ command: String, on text: String, in folder: TransformFolder?,
        seconds: TimeInterval? = nil
    ) -> String? {
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
        process.currentDirectoryURL = workingDirectory(for: command, in: folder)

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

    /// Where a command runs: **the directory of the first file it names.**
    ///
    /// One rule, because the two obvious ones are each wrong half the time. The
    /// folder alone breaks an upgrade — seeding writes
    /// `transforms/<name>/cases.yaml` even when the script stays beside
    /// `config.yaml`, so the folder exists while nothing in the command lives in
    /// it, and a script that has read `roster.json` from beside `config.yaml`
    /// for months is started somewhere that never held one. The config
    /// directory alone breaks the folder, which is the whole point of it.
    ///
    /// The arguments are searched too, and that is not thoroughness for its own
    /// sake. `python3 legacy.py` is how a config that predates folders names a
    /// script: the program is a bare interpreter the shell finds on PATH, so
    /// nothing about the program says where the transform lives, and only
    /// `legacy.py` does. Getting it wrong there is the same silent failure —
    /// the interpreter cannot find the file, the command exits non-zero, and a
    /// non-zero command keeps the transcript.
    ///
    /// Only the working directory is decided here. `parts` still reports the
    /// *program*, because that is what `complaint` checks the execute bit of,
    /// and `python3 legacy.py` needs no execute bit on `legacy.py`.
    ///
    /// Nothing names a file — a bare `sed`, `tr '[:lower:]' '[:upper:]'` — and
    /// the folder is right: it is where a transform's own files are, and a
    /// one-liner that reads none does not care either way.
    static func workingDirectory(for command: String, in folder: TransformFolder) -> URL {
        let (_, arguments, resolved) = parts(of: command, in: folder)
        if let resolved { return resolved.url.deletingLastPathComponent() }

        for token in words(of: arguments) {
            // A flag is not a path.
            guard !token.hasPrefix("-"), let found = folder.resolve(token) else { continue }
            // The directory it was found *under*, not the one it lives in.
            //
            // The program is rewritten to an absolute path before the shell
            // sees it, so moving the working directory cannot disturb it. An
            // argument is not: it reaches the shell exactly as written, and
            // the shell resolves it against the working directory we set. Set
            // that to the file's own directory and the relative path is
            // counted twice — `python3 'my scripts/rewrite.py'` looked for
            // `my scripts/my scripts/rewrite.py`, which is a directory nobody
            // has. What the argument is relative *to* is the answer, and that
            // is also what the command ran in before folders existed.
            return found.base ?? found.url.deletingLastPathComponent()
        }
        return folder.workingDirectory
    }

    /// An argument list split the way the shell will split it: on spaces that
    /// are not inside quotes, with the quotes removed.
    ///
    /// Splitting on every space instead is wrong for the one case that most
    /// needs to work — `python3 'my scripts/rewrite.py'`, where the quotes are
    /// there precisely because the path has a space in it. That is the same
    /// problem `parts` solves for the program, and it has the same answer:
    /// a space is an ordinary character in a path, so something has to say
    /// which spaces are separators. On the program side the file system says;
    /// here the quoting does, because by the time this runs the quotes are
    /// still on the string — YAML gave it to us verbatim.
    ///
    /// Not a shell parser. Escapes, `$(…)` and word splitting are the shell's,
    /// and a command that needs them is one whose working directory is not
    /// going to be decided by reading it.
    static func words(of arguments: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in arguments {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
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
    static func complaint(about command: String, in folder: TransformFolder?) -> String? {
        let (program, _, resolved) = parts(of: command, in: folder)
        let fm = FileManager.default
        guard resolved != nil, fm.fileExists(atPath: program),
              !fm.isExecutableFile(atPath: program) else { return nil }
        return "\(program) is not executable — chmod +x it"
    }
}
