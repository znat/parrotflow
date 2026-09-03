import AppKit
import Foundation

/// Installing espeak-ng, which this app never does for you.
///
/// It is GPL-3 and a separate program: nothing is bundled and nothing is
/// fetched. The setup screen offers the one line that installs it and runs
/// that line in Terminal, where it can be read while it runs. `Phonemes.binary`
/// is what notices it afterwards.
enum EspeakInstall {

    /// Homebrew, if it is there. The two places it installs itself.
    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The line to run. Without Homebrew its own installer is chained in front,
    /// because `brew install` on a Mac with no brew is an error message.
    static var command: String {
        guard brew == nil else { return "brew install espeak-ng" }
        return "/bin/bash -c \"$(curl -fsSL"
            + " https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            + " && brew install espeak-ng"
    }

    static func copyCommand() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(command, forType: .string)
    }

    /// Opens Terminal on a script holding the command.
    ///
    /// A script rather than AppleScript's `do script`: telling Terminal what to
    /// run is an Apple Event, and that puts an Automation permission prompt in
    /// front of someone who is still granting the first two.
    @discardableResult
    static func runInTerminal() -> Bool {
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else {
            Log.write("espeak: Terminal.app not found")
            return false
        }

        let script = AppVariant.supportDirectory
            .appendingPathComponent("install-espeak-ng.command")
        do {
            try FileManager.default.createDirectory(
                at: AppVariant.supportDirectory, withIntermediateDirectories: true
            )
            try "#!/bin/bash\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path
            )
        } catch {
            Log.write("espeak: could not write the install script — \(error.localizedDescription)")
            return false
        }

        NSWorkspace.shared.open(
            [script], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                Log.write("espeak: Terminal did not open — \(error.localizedDescription)")
            }
        }
        return true
    }
}
