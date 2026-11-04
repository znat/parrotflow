import Foundation

/// Model caches an earlier version downloaded and this one does not read.
///
/// A cache the app has stopped fetching is not a cache the app has stopped
/// keeping. Nothing ever deleted `models/modernbert-base-64`, so every machine
/// that ran a version before this one is holding 300 MB for a model no stage
/// opens: the boundary reads Qwen through `SentenceReadings` and the
/// vocabulary slot gate reads mmBERT-small through `SlotModel`.
///
/// `mmbert-small-64` is the slot model's own earlier cache. `SlotModel` prunes
/// it once the parrotflow-syrinx package has loaded, so a machine is never
/// left with neither. `parrotflow-syrinx` and `parrot-syrinx` are the fp32
/// parser caches dev builds fetched; `SyrinxParser` prunes them once it loads.
///
/// Only the names listed here, and only inside `models/`. Everything else in
/// that directory is a model the app still fetches, and re-downloading one by
/// accident costs somebody a launch.
enum RetiredModels {

    /// `lock` is the one the version that fetched the model took around its
    /// download. It sits beside the cache directory rather than inside it, so
    /// a fetch that deletes the cache does not delete the lock it is holding.
    struct Cache {
        let name: String
        let label: String
        let size: String

        var lock: String { "\(name).lock" }

        static let modernBERT = Cache(name: "modernbert-base-64", label: "ModernBERT", size: "about 300 MB")
        static let mmBERTSmall = Cache(name: "mmbert-small-64", label: "mmBERT-small", size: "about 282 MB")
        static let syrinx = Cache(name: "parrotflow-syrinx", label: "fp32 parrotflow-syrinx", size: "about 509 MB")
        static let parrotSyrinx = Cache(name: "parrot-syrinx", label: "parrot-syrinx", size: "about 509 MB")
    }

    /// Removes the cache once, quietly. A machine that never had it does
    /// nothing and says nothing.
    ///
    /// The lock is taken first, and a launch that cannot take it leaves
    /// everything alone. An older build can still be downloading into this
    /// directory — `--sentence-model` from an old `/Applications` copy, or an
    /// app that has not been replaced yet — and deleting the directory under it
    /// fails its next write. `flock` follows the open file, not the name, so
    /// unlinking the lock would not stop that process; it would only let a
    /// third one take a fresh lock and start a second download.
    static func prune(_ retired: Cache, in supportDirectory: URL) {
        let files = FileManager.default
        let models = supportDirectory.appendingPathComponent("models", isDirectory: true)
        let cache = models.appendingPathComponent(retired.name, isDirectory: true)
        let lock = models.appendingPathComponent(retired.lock)
        guard files.fileExists(atPath: cache.path) else { return }

        let handle = open(lock.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { return }
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            Log.write("models: the retired \(retired.label) cache is in use;"
                + " leaving it for the next launch")
            return
        }

        do {
            try files.removeItem(at: cache)
        } catch {
            Log.write("models: could not remove the retired \(retired.label) cache —"
                + " \(error.localizedDescription)")
            return
        }
        // Last, and still under the lock, so nothing is downloading when the
        // name goes. Left behind if it will not go: an empty file is not worth
        // a second error line.
        try? files.removeItem(at: lock)
        Log.write("models: removed the retired \(retired.label) cache, \(retired.size)")
    }
}
