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
    static func run(_ command: String, on text: String, base: URL?) -> String? {
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
        process.arguments = ["-c", resolved(command, base: base)]
        process.currentDirectoryURL = base

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Read while it runs. A script that writes more than a pipe buffer
        // before exiting would otherwise block on the write while we block on
        // waitUntilExit, and neither side would ever move.
        var collected = Data()
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                done.signal()
            } else {
                collected.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            Log.write("command: could not run \"\(command)\": \(error.localizedDescription)")
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            output.fileHandleForReading.readabilityHandler = nil
            Log.write("command: \"\(command)\" took longer than \(Int(timeout))s; kept the transcript")
            return nil
        }
        process.waitUntilExit()

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

        // Trailing newline only: a script that legitimately indents its output
        // is not this app's business, and `print` adds exactly one newline.
        var result = String(data: collected, encoding: .utf8) ?? ""
        if result.hasSuffix("\n") { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    /// The command with `~` expanded and, if its first word names a file next
    /// to the config, that word made absolute.
    ///
    /// Setting the working directory alone would not be enough: a shell looks a
    /// bare `identifiers.py` up in PATH, not in the directory it is standing
    /// in, so it would report "command not found" while the file sat right
    /// there. `./identifiers.py` would have worked, and requiring the `./` is
    /// the kind of detail that costs someone twenty minutes once.
    ///
    /// Existing is enough to be resolved — being executable is not required
    /// here, deliberately. A script that is there but not `chmod +x` is the
    /// single most likely thing to be wrong, and it deserves to be told about
    /// as itself rather than as "command not found", which sends you looking
    /// in the wrong place. `complaint` is what says it.
    static func resolved(_ command: String, base: URL?) -> String {
        let base = base ?? ConfigStore.directory
        let expanded = (command as NSString).expandingTildeInPath
        guard let first = expanded.split(separator: " ", maxSplits: 1).first,
              !first.hasPrefix("/") else { return expanded }
        let candidate = base.appendingPathComponent(String(first)).standardized
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return expanded
        }
        return candidate.path + expanded.dropFirst(first.count)
    }

    /// What is wrong with this command before it is even run, in words, or nil
    /// if nothing obvious is.
    ///
    /// Only the case that is worth naming: the file is where it should be and
    /// the system will refuse to run it. Everything else — a typo in the name,
    /// an interpreter that is not installed — is the shell's to report, and it
    /// reports those well.
    static func complaint(about command: String, base: URL?) -> String? {
        let path = String(
            resolved(command, base: base).split(separator: " ", maxSplits: 1).first ?? ""
        )
        let fm = FileManager.default
        guard path.hasPrefix("/"), fm.fileExists(atPath: path),
              !fm.isExecutableFile(atPath: path) else { return nil }
        return "\(path) is not executable — chmod +x it"
    }
}
