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
            print(await Replacements.apply(to: text, config: config))
            done.signal()
        }
        done.wait()
        return 0
    }
}
