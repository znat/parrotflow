import Foundation

/// `--replace "<text>" [--app <name>]` — runs the replacement passes over a
/// line and prints the result. Lets the substitution logic be exercised without
/// dictating.
///
/// `--app` says who to pretend was in front, because otherwise a stage carrying
/// an `app:` condition is unreachable from here: with no app a positive
/// condition fails closed, so every such stage would be reported as doing
/// nothing, and the one way left to check your own rules would be to dictate
/// into each app in turn. Same string as `--pipeline --app`, matched the same
/// way — name and bundle identifier joined.
enum ReplaceCommand {
    static func run(text: String, app: String? = nil) -> Int32 {
        guard let config = try? ConfigStore.load() else {
            print("✗ could not read config")
            return 1
        }
        let named = (app ?? "").trimmingCharacters(in: .whitespaces)
        let front = named.isEmpty ? nil : Pipeline.App(name: named, bundleID: "")
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
            print(await Replacements.apply(
                to: text, config: config, allowPrompts: false, app: front
            ))
            done.signal()
        }
        done.wait()
        return 0
    }
}
