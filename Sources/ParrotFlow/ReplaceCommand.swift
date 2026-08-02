import Foundation

/// `--replace "<text>"` — runs the replacement passes over a line and prints
/// the result. Lets the substitution logic be exercised without dictating.
enum ReplaceCommand {
    static func run(text: String) -> Int32 {
        guard let config = try? ConfigStore.load() else {
            print("✗ could not read config")
            return 1
        }
        // A command exits the moment it has printed, so it has to wait for
        // the pipeline rather than return into an empty runloop.
        let done = DispatchSemaphore(value: 0)
        Task {
            // Deterministic passes only. This command is what
            // scripts/check-replacements.sh scores, and a `prompt` stage in
            // the config would send every case to the model and repunctuate
            // it — a replacement set failing wholesale for a reason that has
            // nothing to do with the replacement table. It is also not what
            // the name promises: --replace should not reach the network.
            print(await Replacements.apply(to: text, config: config, allowPrompts: false))
            done.signal()
        }
        done.wait()
        return 0
    }
}
