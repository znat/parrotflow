import Foundation

/// Model caches an earlier version downloaded and this one does not read.
///
/// A cache the app has stopped fetching is not a cache the app has stopped
/// keeping. Nothing ever deleted `models/modernbert-base-64`, so every machine
/// that ran a version before this one is holding 300 MB for a model no stage
/// opens: the boundary reads Qwen through `SentenceReadings` and the
/// vocabulary slot gate reads mmBERT-small through `SlotModel`.
///
/// Only the names listed here, and only inside `models/`. Everything else in
/// that directory is a model the app still fetches, and re-downloading one by
/// accident costs somebody a launch.
enum RetiredModels {

    /// What ModernBERT left behind. The lock sits beside its directory rather
    /// than inside it, which is why it is named separately.
    private static let names = ["modernbert-base-64", "modernbert-base-64.lock"]

    /// Removes them once, quietly. A machine that never had them does nothing
    /// and says nothing.
    static func prune(in supportDirectory: URL) {
        let files = FileManager.default
        let models = supportDirectory.appendingPathComponent("models", isDirectory: true)
        let present = names
            .map { models.appendingPathComponent($0) }
            .filter { files.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return }

        var removed: [String] = []
        var failures: [String] = []
        for url in present {
            do {
                try files.removeItem(at: url)
                removed.append(url.lastPathComponent)
            } catch {
                failures.append("\(url.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        Log.write("models: removed the retired ModernBERT cache — "
            + (removed.isEmpty ? "nothing" : removed.joined(separator: ", "))
            + (failures.isEmpty ? "" : "; could not remove \(failures.joined(separator: ", "))"))
    }
}
