import Foundation

/// Fetches files from a public HuggingFace repository.
///
/// Ours rather than FluidAudio's `ModelHub`, which is the only downloader
/// already linked here: its `Repo` is a closed enum, so it cannot be pointed at
/// a repository outside its own list.
///
/// The failure this is built against is a truncated file. A `weight.bin` that
/// stops at 200 of its 299 MB still opens, and a model loaded from it returns
/// numbers rather than an error. So every file is fetched to a temporary path,
/// its length is checked against the repository listing, and only then does it
/// move into the caller's directory.
enum HubDownload {

    enum Failure: LocalizedError {
        case http(path: String, status: Int)
        case unlisted(path: String)
        case truncated(path: String, expected: Int64, got: Int64)

        var errorDescription: String? {
            switch self {
            case .http(let path, let status):
                return "\(path): HTTP \(status)"
            case .unlisted(let path):
                return "\(path): not in the repository listing"
            case .truncated(let path, let expected, let got):
                return "\(path): \(got) bytes of \(expected)"
            }
        }
    }

    static func url(repo: String, path: String) -> URL? {
        let escaped = path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(escaped)")
    }

    /// Downloads `paths` into `directory`, keeping the repository's own layout.
    ///
    /// `progress` gets the fraction of the whole set, so the caller reports one
    /// number rather than one per file. Sequential, not parallel: one 299 MB
    /// file is 99% of this set, and racing three small ones against it only
    /// makes the number jump.
    static func fetch(
        repo: String,
        paths: [String],
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let listed = try await sizes(repo: repo)
        var sizes: [String: Int64] = [:]
        for path in paths {
            guard let size = listed[path] else { throw Failure.unlisted(path: path) }
            sizes[path] = size
        }
        let total = sizes.values.reduce(0, +)

        var done: Int64 = 0
        for path in paths {
            let expected = sizes[path] ?? 0
            let before = done
            try await download(
                repo: repo, path: path, expecting: expected,
                to: directory.appendingPathComponent(path)
            ) { written in
                progress(Double(before + min(written, expected)) / Double(max(total, 1)))
            }
            done += expected
            progress(Double(done) / Double(max(total, 1)))
        }
    }

    /// Every file in the repository with its length, from one call.
    ///
    /// Not `Content-Length` on the download. HuggingFace serves `tokenizer.json`
    /// gzipped, and a gzipped response carries no length at all — the header
    /// that does arrive describes the compressed bytes, not the file. This
    /// listing gives the real size, which is what the length check needs.
    private static func sizes(repo: String) async throws -> [String: Int64] {
        let path = "api/models/\(repo)/tree/main?recursive=true"
        guard let url = URL(string: "https://huggingface.co/\(path)") else { return [:] }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(path: path, status: http.statusCode)
        }
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var sizes: [String: Int64] = [:]
        for entry in entries {
            guard entry["type"] as? String == "file",
                  let path = entry["path"] as? String,
                  let size = (entry["size"] as? NSNumber)?.int64Value
            else { continue }
            sizes[path] = size
        }
        return sizes
    }

    private static func download(
        repo: String,
        path: String,
        expecting: Int64,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let url = url(repo: repo, path: path) else {
            throw Failure.unlisted(path: path)
        }
        let watcher = Watcher(onWrite: progress)
        // Session delegate, not the `delegate:` of `download(from:delegate:)`.
        // That one only gets life-cycle and authentication callbacks, so
        // `didWriteData` never arrives and the fetch reports 0% then 100%.
        let session = URLSession(configuration: .default, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let temporary = try await withCheckedThrowingContinuation { continuation in
            watcher.begin(continuation)
            session.downloadTask(with: url).resume()
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        if let status = watcher.status, status != 200 {
            throw Failure.http(path: path, status: status)
        }

        let got = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        guard got == expecting else {
            throw Failure.truncated(path: path, expected: expecting, got: got)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Reports bytes as they land and hands back the finished file.
    private final class Watcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onWrite: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private(set) var status: Int?

        init(onWrite: @escaping @Sendable (Int64) -> Void) {
            self.onWrite = onWrite
        }

        func begin(_ continuation: CheckedContinuation<URL, Error>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            onWrite(totalBytesWritten)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            // The file is deleted the moment this returns, so it has to move
            // here rather than after the await.
            let kept = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("parrotflow-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                finish(.success(kept))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            // Runs after `didFinishDownloadingTo` on success, where the
            // continuation is already gone and this does nothing.
            finish(.failure(error ?? URLError(.unknown)))
        }
    }
}
