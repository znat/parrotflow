import Foundation

/// Appends to `~/Library/Logs/ParrotFlow.log`.
///
/// A menu bar app has no terminal to print to, and `NSLog` output is awkward to
/// retrieve from the unified log. Since most of what goes wrong here is
/// permissions and hotkey registration — both invisible at the moment they
/// fail — a plain file you can `tail -f` is worth the few lines.
enum Log {
    static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(AppVariant.logFileName)")

    /// `config.logging.text`. True until a config has actually loaded, so
    /// nothing written before then — including a config that fails to parse
    /// — is lost. Set from `ConfigStore.load()`.
    static var textEnabled = true

    private static let queue = DispatchQueue(label: "com.parrotflow.log")

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Waits for queued writes to reach the file.
    ///
    /// Writing asynchronously is right for a menu bar app and wrong for a
    /// terminal command, which exits the instant it has finished: the process
    /// is gone before the queue drains and the lines are silently lost. Any
    /// CLI path that logs has to flush before it exits.
    static func flush() {
        queue.sync {}
    }

    /// - Parameter force: writes to the file even with `textEnabled` off. For
    ///   the handful of commands whose only transport this is — `--peek` and
    ///   `--edit-test`/`--span-test` are read out of this file by a harness
    ///   because LaunchServices throws their stdout away. Everything else
    ///   respects the setting.
    static func write(_ message: String, force: Bool = false) {
        let line = "\(timestampFormatter.string(from: Date()))  \(message)\n"

        guard force || textEnabled else { return }
        // Behind the guard, not before it. The unified log outlives the
        // process and `log show` reads it back, so a line carrying dictated
        // text has to respect `logging.text` at this sink too.
        NSLog("[ParrotFlow] %@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                // Keep it from growing without bound; this is a debug aid, not
                // an audit trail.
                if (try? handle.seekToEnd()) ?? 0 > 1_000_000 {
                    try? handle.truncate(atOffset: 0)
                    try? handle.seek(toOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? fm.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: fileURL)
            }
        }
    }
}
