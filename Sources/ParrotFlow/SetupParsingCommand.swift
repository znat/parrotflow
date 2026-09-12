import Foundation

/// `--setup-parsing` — installs the Python a parsing transform needs, and says
/// where it went.
///
/// A command and not a button. The setup screen offers eSpeak NG because a
/// dictation cannot spell a name without it; this is 170 MB for a stage nobody
/// has yet, and the audience for it is somebody who is already in a terminal.
///
/// `--check` reports and changes nothing, which is what a script wants.
///
/// The app installs this by itself the first time a transform asks for a parse
/// — see `ParsingInstall.finishQuietly`, which builds the venv on the
/// interpreter a transform will actually run under. This command picks its own,
/// and the two can differ: a venv built here on Homebrew's python is invisible
/// to an app launched from the Dock, which resolves `/usr/bin/python3`.
enum SetupParsingCommand {

    static func run(check: Bool) -> Int32 {
        report()

        let steps = ParsingInstall.steps()
        if steps.isEmpty {
            print("\nNothing to do.")
            printUsage()
            return 0
        }

        if check {
            print("\n\(steps.count) step(s) missing. Run without --check to install:")
            for step in steps { print("    \(step.command)") }
            return 1
        }

        print("\nAbout 170 MB, into \(ParsingInstall.root.path)\n")
        for step in steps {
            print("==> \(step.what)")
            print("    \(step.command)")
            let status = shell(step.command)
            guard status == 0 else {
                print("\n✗ that step exited \(status). Nothing after it ran.")
                return status
            }
        }

        print("")
        report()
        guard ParsingInstall.steps().isEmpty else {
            print("\n✗ something is still missing. Run again to see what.")
            return 1
        }
        printUsage()
        return 0
    }

    /// Every piece, with the path, so a failure names the thing that is wrong
    /// rather than the thing that noticed.
    private static func report() {
        line("eSpeak NG", Phonemes.binary)
        line("python3", ParsingInstall.isInstalled ? ParsingInstall.python.path : nil)
        for model in ParsingInstall.models {
            line(model, ParsingInstall.has(model) ? "installed" : nil)
        }
    }

    private static func line(_ what: String, _ found: String?) {
        let width = 16
        let name = what.padding(toLength: max(width, what.count), withPad: " ", startingAt: 0)
        print(found.map { "  ✓ \(name) \($0)" } ?? "  ✗ \(name) not installed")
    }

    private static func printUsage() {
        print("""

            A transform reaches it by naming the interpreter, because an app \
            launched
            from the Dock inherits launchd's PATH and a venv is not on it:

              - name: parse
                command: \(ParsingInstall.python.path) parse.py
                returns: json
            """)
    }

    /// Inherits stdout and stderr, so pip's progress is watched rather than
    /// buffered and reprinted. No deadline: this is a foreground command and
    /// the person running it can stop it.
    private static func shell(_ command: String) -> Int32 {
        // Ours is buffered when stdout is a pipe; the child's is not. Without
        // this the step headings arrive after the output they introduce.
        fflush(stdout)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do { try process.run() } catch {
            print("    could not start /bin/sh — \(error.localizedDescription)")
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
