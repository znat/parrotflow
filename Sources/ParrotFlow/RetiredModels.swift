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

    private static let cacheName = "modernbert-base-64"

    /// The lock the version that fetched this model took around its download.
    /// It sits beside the cache directory rather than inside it, so a fetch
    /// that deletes the cache does not delete the lock it is holding.
    private static let lockName = "modernbert-base-64.lock"

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
    static func prune(in supportDirectory: URL) {
        let files = FileManager.default
        let models = supportDirectory.appendingPathComponent("models", isDirectory: true)
        let cache = models.appendingPathComponent(cacheName, isDirectory: true)
        let lock = models.appendingPathComponent(lockName)
        guard files.fileExists(atPath: cache.path) else { return }

        let handle = open(lock.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { return }
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            Log.write("models: the retired ModernBERT cache is in use;"
                + " leaving it for the next launch")
            return
        }

        do {
            try files.removeItem(at: cache)
        } catch {
            Log.write("models: could not remove the retired ModernBERT cache —"
                + " \(error.localizedDescription)")
            return
        }
        // Last, and still under the lock, so nothing is downloading when the
        // name goes. Left behind if it will not go: an empty file is not worth
        // a second error line.
        try? files.removeItem(at: lock)
        Log.write("models: removed the retired ModernBERT cache, about 300 MB")
    }
}
