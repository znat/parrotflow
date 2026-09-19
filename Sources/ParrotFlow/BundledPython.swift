import Foundation

/// The Python that ships inside the App Store build.
///
/// The other two builds run a `command:` through `/bin/sh`, which resolves a
/// name on PATH and runs whatever it finds. The App Store build cannot: the
/// sandbox executes only what is inside the bundle, and guideline 2.5.2 wants
/// an app self-contained. So this build ships its own interpreter and its own
/// scripts, both signed and read-only in `Contents/Resources`, and runs one
/// with the other — no shell, no PATH, nothing resolved at run time.
///
/// That is also what makes it reviewable. The only thing this can start is a
/// `.py` file that was in the bundle Apple looked at, and `script(for:)` is
/// the check that says so.
///
/// `scripts/fetch-python.sh` builds the interpreter half. It is a statically
/// linked CPython with the extension modules inside the executable, so there
/// is one Mach-O file to sign and library validation has nothing to refuse.
enum BundledPython {

    /// Nil in the dev and release builds, which have no bundled interpreter
    /// and do not want one. Every entry point below is nil there too, so
    /// CommandRunner keeps its shell.
    static var interpreter: URL? {
        guard AppVariant.isAppStore,
              let resources = Bundle.main.resourceURL else { return nil }
        let python = resources
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")
        return FileManager.default.isExecutableFile(atPath: python.path) ? python : nil
    }

    /// `Contents/Resources/examples` — the shipped transforms, run where they
    /// were signed.
    ///
    /// The other builds copy these into `transforms/examples/` on every launch
    /// and run the copy. This one must not: writing an executable script into
    /// the container and then running it is the shape 2.5.2 is about, even
    /// though the file came out of our own bundle. See `Config.createIfMissing`.
    static var scriptsRoot: URL? {
        guard AppVariant.isAppStore else { return nil }
        return Bundle.main.resourceURL?
            .appendingPathComponent("examples", isDirectory: true)
            .standardizedFileURL
    }

    /// The script a `command:` names, or nil if it does not name one of ours.
    ///
    /// Everything about this is deliberately narrow. The command has to start
    /// with a path — relative to the examples directory, or the `examples/...`
    /// spelling the config uses — it has to end in `.py`, and the file it
    /// resolves to has to sit inside that directory once the path is
    /// standardised. `..` therefore cannot walk out of it, and a symlink
    /// pointing outside resolves before the check rather than after.
    static func script(for command: String) -> (url: URL, arguments: [String])? {
        guard let root = scriptsRoot else { return nil }

        // Split on the first space only. A script path with a space in it is
        // not something this build can be given: the config that names it is
        // ours and the file is ours.
        let pieces = command.split(separator: " ").map(String.init)
        guard var first = pieces.first, first.hasSuffix(".py") else { return nil }

        // `examples/dates/en.py` and `dates/en.py` are the same file. The
        // config says the first because that is what the other builds resolve.
        if first.hasPrefix("examples/") { first = String(first.dropFirst("examples/".count)) }

        let candidate = root.appendingPathComponent(first).standardizedFileURL
        let inside = candidate.path.hasPrefix(root.path + "/")
        guard inside, FileManager.default.isReadableFile(atPath: candidate.path) else {
            return nil
        }
        return (candidate, Array(pieces.dropFirst()))
    }

    /// What `Process` should be pointed at, or nil to leave CommandRunner's
    /// shell alone.
    static func invocation(for command: String) -> (executable: URL, arguments: [String])? {
        guard let interpreter, let found = script(for: command) else { return nil }
        return (interpreter, [found.url.path] + found.arguments)
    }

    /// Why a command cannot run here, for the log and for `--check-config`.
    ///
    /// Only reached in the App Store build. A `command:` that names one of our
    /// scripts has no complaint; anything else — a shell line, a program on
    /// PATH, a script of the user's own — cannot run and should say so once
    /// rather than look like a rule that did not match.
    static func complaint(about command: String) -> String? {
        guard AppVariant.isAppStore else { return nil }
        guard interpreter != nil else {
            return "this build has no bundled interpreter, so `command:` cannot run"
        }
        guard script(for: command) != nil else {
            return "this build runs only the scripts it ships, so `\(command)` cannot run"
                + " — install the build at github.com/znat/parrotflow for your own"
        }
        return nil
    }

    /// The two variables the bundle's own interpreter needs.
    ///
    /// `PYTHONHOME` because the executable is not where its standard library
    /// is once both are inside Resources, and without it the interpreter exits
    /// before running anything with a message about encodings.
    ///
    /// `PYTHONDONTWRITEBYTECODE` because the bundle is signed and read-only: a
    /// `.pyc` written beside a `.py` at first import would fail, and would
    /// invalidate the signature if it did not. `fetch-python.sh` precompiles
    /// the standard library so nothing is paid for turning this off.
    static func apply(to process: Process) {
        guard let interpreter else { return }
        let home = interpreter
            .deletingLastPathComponent()   // bin/
            .deletingLastPathComponent()   // python/
        var environment = process.environment ?? ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = home.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
    }
}
