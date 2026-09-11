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
