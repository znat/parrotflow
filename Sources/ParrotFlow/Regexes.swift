import Foundation

/// Compiled patterns, kept for the life of the process.
///
/// The patterns come from the config — replacement rules, vocabulary
/// renderings, activation phrases — so the same handful is compiled again on
/// every dictation. The set is bounded by what the loaded configs contain,
/// and `NSRegularExpression` is immutable and thread-safe, so one copy each
/// is enough.
enum Regexes {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    /// Patterns that did not parse, so a bad rule is not re-compiled on every
    /// dictation either.
    private static var failed: Set<String> = []

    static func compiled(
        _ pattern: String, options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)"
        lock.lock()
        if let found = cache[key] { lock.unlock(); return found }
        if failed.contains(key) { lock.unlock(); return nil }
        lock.unlock()

        let built = try? NSRegularExpression(pattern: pattern, options: options)
        lock.lock()
        if let built { cache[key] = built } else { failed.insert(key) }
        lock.unlock()
        return built
    }
}
