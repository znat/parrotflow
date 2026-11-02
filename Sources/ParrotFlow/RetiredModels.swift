import Foundation

/// Model caches an earlier version downloaded and this one does not read.
///
/// A cache the app has stopped fetching is not a cache the app has stopped
/// keeping. Nothing deletes them otherwise, so every machine that ran an
/// earlier version would keep holding them for models no stage opens.
///
/// Only the names listed here, and only inside `models/` or, for the term
/// portraits, the one file in the support directory. Everything else is a
/// model the app still fetches, and re-downloading one by accident costs
/// somebody a launch.
enum RetiredModels {

    struct Cache {
        let name: String
        /// The directory under `models/`.
        let directory: String
        /// The lock the version that fetched this model took around its
        /// download. It sits beside the cache directory rather than inside
        /// it, so a fetch that deletes the cache does not delete the lock it
        /// is holding.
        let lock: String
        let megabytes: Int
    }

    static let caches = [
        Cache(name: "ModernBERT", directory: "modernbert-base-64",
              lock: "modernbert-base-64.lock", megabytes: 300),
        Cache(name: "mmBERT-small", directory: "mmbert-small-64",
              lock: "mmbert-small-64.lock", megabytes: 282),
        Cache(name: "Qwen3 Embedding", directory: "qwen3-embedding-0.6b-4bit",
              lock: "qwen3-embedding.lock", megabytes: 335),
    ]

    /// The term portraits the word vectors were summarised into. Not
    /// `portraits-parrotflow-syrinx-*.json`: that one is the clause decider's.
    static let files = ["portraits-qwen3-embedding-0.6b-4bit.json"]

    /// Removes each cache once, quietly. A machine that never had it does
    /// nothing and says nothing.
    static func prune(in supportDirectory: URL) {
        let models = supportDirectory.appendingPathComponent("models", isDirectory: true)
        for cache in caches {
            prune(cache, in: models)
        }
        for file in files {
            let url = supportDirectory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                Log.write("models: removed the retired \(file)")
            } catch {
                Log.write("models: could not remove the retired \(file) — \(error.localizedDescription)")
            }
        }
    }

    /// The lock is taken first, and a launch that cannot take it leaves
    /// everything alone. An older build can still be downloading into this
    /// directory — an old `/Applications` copy, or an app that has not been
    /// replaced yet — and deleting the directory under it fails its next
    /// write. `flock` follows the open file, not the name, so unlinking the
    /// lock would not stop that process; it would only let a third one take a
    /// fresh lock and start a second download.
    private static func prune(_ retired: Cache, in models: URL) {
        let files = FileManager.default
        let cache = models.appendingPathComponent(retired.directory, isDirectory: true)
        let lock = models.appendingPathComponent(retired.lock)
        guard files.fileExists(atPath: cache.path) else { return }

        let handle = open(lock.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { return }
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            Log.write("models: the retired \(retired.name) cache is in use;"
                + " leaving it for the next launch")
            return
        }

        do {
            try files.removeItem(at: cache)
        } catch {
            Log.write("models: could not remove the retired \(retired.name) cache —"
                + " \(error.localizedDescription)")
            return
        }
        // Last, and still under the lock, so nothing is downloading when the
        // name goes. Left behind if it will not go: an empty file is not worth
        // a second error line.
        try? files.removeItem(at: lock)
        Log.write("models: removed the retired \(retired.name) cache, about \(retired.megabytes) MB")
    }
}
