import Foundation

/// `--replace "<text>"` — runs the replacement passes over a line and prints
/// the result. Lets the substitution logic be exercised without dictating.
enum ReplaceCommand {
    static func run(text: String) -> Int32 {
        guard let config = try? ConfigStore.load() else {
            print("✗ could not read config")
            return 1
        }
        print(Replacements.apply(to: text, config: config))
        return 0
    }
}
