import Foundation

/// The Python a `command:` transform uses when it needs a parse, and the lines
/// that put it there.
///
/// Same rule as `EspeakInstall`: nothing is bundled and the app never installs
/// it for you. spaCy's French model is LGPL-LR and its English model is MIT, so
/// shipping either would be a redistribution question. A tree the person
/// installs themselves is not.
///
/// `Phonemes` and `NLTagger` cover everything the pipeline does today. This is
/// for a stage that wants dependency arcs, which no Apple API gives.
enum ParsingInstall {

    /// One copy for both builds, unlike everything else in `AppVariant`.
    ///
    /// The config and the model cache are split per variant so a half-finished
    /// feature cannot break the install you rely on. This is neither: it is a
    /// third-party interpreter nobody edits, and 170 MB twice buys nothing.
    ///
    /// `PARROTFLOW_PARSING_ROOT` points it somewhere else, which is the only
    /// way to score this against a tree that is not the one on this Mac.
    static var root: URL {
        let override = ProcessInfo.processInfo.environment["PARROTFLOW_PARSING_ROOT"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("ParrotFlow", isDirectory: true)
            .appendingPathComponent("python", isDirectory: true)
    }

    /// What a transform names in its `command:`. An absolute path, because a
    /// GUI app inherits launchd's PATH — `/usr/bin:/bin:/usr/sbin:/sbin` — and
    /// a venv the person made in Terminal is not on it.
    static var python: URL { root.appendingPathComponent("bin/python3") }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
    }

    /// The models this installs. English is MIT. French is LGPL-LR, from UD
    /// French Sequoia, with WikiNER under CC BY 4.0 inside it.
    static let models = ["en_core_web_sm", "fr_core_news_sm"]

    /// The interpreter the venv would be built on.
    ///
    /// `PARROTFLOW_PYTHON` first, so a test can point at one. Homebrew before
    /// `/usr/bin/python3`: the system one is a shim, and on a Mac with no
    /// developer tools it opens an installer dialog rather than running —
    /// which is not something to hit halfway through a setup run.
    ///
    /// `isExecutableFile` cannot tell the two apart: the shim is a real
    /// executable either way. And the obvious test, running it, is the thing
    /// that opens the dialog. So the shim is accepted only when the tools it
    /// forwards to are installed, which `xcode-select -p` answers without
    /// prompting for anything.
    static func interpreter() -> String? {
        var places: [String] = []
        if let named = ProcessInfo.processInfo.environment["PARROTFLOW_PYTHON"] {
            places.append(named)
        }
        places += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        if developerToolsInstalled() {
            places.append("/usr/bin/python3")
        }
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether `/usr/bin/python3` forwards to anything.
    ///
    /// `xcode-select -p` prints the developer directory and exits 0 when the
    /// tools are there, and exits non-zero when they are not. It is the one
    /// question that can be asked without triggering the install prompt.
    static func developerToolsInstalled() -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        probe.arguments = ["-p"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        let printed = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return false }
        let path = String(decoding: printed, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    /// Whether the tree can answer for a model. Runs it rather than looking for
    /// a directory: a half-finished `pip install` leaves the directory behind.
    static func has(_ model: String) -> Bool {
        guard isInstalled else { return false }
        let probe = Process()
        probe.executableURL = python
        probe.arguments = ["-c", "import \(model)"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    /// The pinned manifest. Bundled beside the other data files; the repo copy
    /// is what a build directory run reads, the same fallback `WordPieces` uses.
    static var requirements: URL {
        let override = ProcessInfo.processInfo.environment["PARROTFLOW_REQUIREMENTS"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if !Permissions.isRunningFromBuildDirectory,
           let bundled = Bundle.main.resourceURL?
               .appendingPathComponent("parsing-requirements.txt"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ParsingInstall.swift -> Sources/ParrotFlow/
            .deletingLastPathComponent()  // -> Sources/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("data/parsing-requirements.txt")
    }

    /// What is missing, in the order it has to be installed.
    ///
    /// One `pip install -r` rather than a line per package: the manifest pins
    /// the models by URL, and `spacy download` would pick its own version.
    static func steps() -> [Step] {
        var out: [Step] = []
        if Phonemes.binary == nil {
            out.append(Step(what: "eSpeak NG", command: EspeakInstall.command))
        }
        if !isInstalled {
            guard let interpreter = interpreter() else {
                // Every step below names the venv's own interpreter, and there
                // is no venv without one to build it with. Saying so here
                // rather than in the caller is what makes `--check` honest:
                // it used to print the pip line for a path that could not
                // exist, and never mention the missing python at all.
                out.append(Step(
                    what: "a python3 to build the venv with",
                    command: EspeakInstall.brew.map { "\($0) install python" }
                        ?? "xcode-select --install"))
                return out
            }
            out.append(Step(
                what: "a Python for parsing",
                command: "\(shellQuoted(interpreter)) -m venv \(shellQuoted(root.path))"))
        }
        if !isInstalled || models.contains(where: { !has($0) }) {
            out.append(Step(
                what: "spaCy and its models",
                command: "\(shellQuoted(python.path)) -m pip install --upgrade"
                    + " --disable-pip-version-check -r \(shellQuoted(requirements.path))"))
        }
        return out
    }

    // MARK: - Finishing it without a terminal

    /// Everything a parse needs is here, eSpeak NG aside.
    static var isComplete: Bool { isInstalled && models.allSatisfy(has) }

    /// Installs it quietly, once eSpeak NG is here.
    ///
    /// Two callers, and both know a real `python3` exists before they ring.
    /// At launch and when the setup window sees eSpeak NG land: eSpeak NG came
    /// from Homebrew, and the Homebrew installer installs the Command Line
    /// Tools, so `/usr/bin/python3` is an interpreter rather than the shim that
    /// opens Apple's installer dialog. From `Pipeline`, when a transform
    /// publishes `needs: parsing`: that transform just ran, so one resolved.
    ///
    /// It was first-need only for a while. Measured on 24,576 dictations, the
    /// first one carrying a marker was number 10 and all 33 days had one — so
    /// waiting saved nobody the 170 MB and cost that first dictation its rule.
    /// The `needs: parsing` path stays as the way in for a Mac that never
    /// installed eSpeak NG.
    ///
    /// Built on the interpreter a transform will actually run under, not on
    /// whichever one this process would pick. `--setup-parsing` prefers
    /// Homebrew's; an app launched from the Dock inherits launchd's PATH and
    /// resolves `/usr/bin/python3`. A venv built on one and read by the other
    /// is invisible — four green ticks from the command and the rule still off.
    /// Asking `CommandRunner` is what makes them the same by construction.
    ///
    /// Fails open, into the log. Nothing waits for it.
    static func finishQuietly() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            defer {
                lock.lock()
                running = false
                lock.unlock()
            }
            // Asked here rather than at the call site. `isComplete` runs the
            // venv's own python once per model, and both callers are on the
            // main thread — two process launches there is a stutter in the
            // window that is drawing at the time.
            guard !isComplete else { return }
            guard let interpreter = CommandRunner.transformInterpreter() else {
                Log.write("parsing: no python3 a transform could run — nothing installed")
                return
            }
            var lines: [(String, String)] = []
            if !isInstalled {
                lines.append((
                    "a Python for parsing",
                    "\(shellQuoted(interpreter)) -m venv \(shellQuoted(root.path))"))
            }
            lines.append((
                "spaCy and its models",
                "\(shellQuoted(python.path)) -m pip install --upgrade"
                    + " --disable-pip-version-check -r \(shellQuoted(requirements.path))"))

            for (what, command) in lines {
                let status = run(command)
                guard status == 0 else {
                    Log.write("parsing: \(what) exited \(status); nothing after it ran")
                    return
                }
            }
            Log.write(isComplete
                ? "parsing: spaCy is in — the disfluency marker rule runs from now on"
                : "parsing: the install finished and something is still missing")
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running = false

    /// Long enough for 170 MB of wheels on a bad connection, and short enough
    /// that a fetch which has stopped moving does not hold `running` for the
    /// life of the app. `--setup-parsing` has no deadline because a person is
    /// watching it and can press ctrl-C; nobody is watching this.
    private static let deadlineSeconds: TimeInterval = 900

    /// Output to the log, not to a pipe nobody reads. pip writes a progress bar
    /// per wheel and none of it is worth keeping.
    private static func run(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `exec`, so the tracked process is pip rather than the shell holding
        // it. Without it the deadline below kills the shell and leaves pip
        // running, `running` clears, and the next caller starts a second
        // install into the same tree. Same reason as `CommandRunner`'s own
        // prefix; these commands are generated here and hold no shell syntax.
        process.arguments = ["-c", "exec " + command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return 1 }

        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard !process.isRunning else {
            Log.write("parsing: the install stopped moving after"
                + " \(Int(deadlineSeconds))s and was terminated")
            // SIGTERM, then SIGKILL, which cannot be ignored. Waiting for the
            // exit is what reaps it — the same shape as `CommandRunner.stop`.
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return process.terminationStatus == 0 ? 1 : process.terminationStatus
        }
        return process.terminationStatus
    }

    struct Step {
        let what: String
        let command: String
    }

    /// Single quotes, because the path holds a space —
    /// `~/Library/Application Support/…`.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
