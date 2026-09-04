import Foundation
import MLX
import MLXLMCommon
@preconcurrency import Tokenizers

/// One MLX model in the application support directory, and the fetch that puts
/// it there.
///
/// Two models are loaded this way — the word vectors and the sentence readings
/// — and the download is the part with the traps in it: a lock so two
/// ParrotFlow processes do not fetch the same weights at once, a staging
/// directory so a half-written cache never loads, and a file list rather than a
/// whole-repository mirror.
///
/// The file list is per model and it is not the whole repository.
/// `model.safetensors.index.json` is absent from these repositories — the
/// weights are one file — and listing it would fail the download on `unlisted`.
struct MLXModelCache: Sendable {

    /// The Hugging Face repository, `owner/name`.
    let repository: String
    /// The commit the files come from. `main` moves; the numbers in the check
    /// scripts were measured against this one.
    let revision: String
    /// Every file that has to be on disk before the model loads.
    let files: [String]
    /// Where they end up.
    let directory: URL
    /// Beside the cache directory, not inside it, so a fetch that clears the
    /// cache does not delete a lock somebody is holding.
    let lockURL: URL
    /// What a progress line calls this model — "word vectors 43%".
    let label: String

    enum Failure: LocalizedError {
        case busy(String)

        var errorDescription: String? {
            switch self {
            case .busy(let label):
                return "another ParrotFlow process is fetching the \(label) model"
            }
        }
    }

    /// Caps the MLX buffer pool, which is process-wide.
    ///
    /// It grows with the variety of shapes it has seen: 1.0 GB after one pass
    /// over the boundary bench and 2.0 GB after four. Measured with both models
    /// resident, 256 MB gives the same 36 ms median as 2 GB and holds 620 MB
    /// less. Called on every model load; setting it twice costs nothing.
    static func limitBufferPool() {
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
    }

    var isCached: Bool {
        files.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Downloads the files unless they are all already there.
    ///
    /// `progress` gets a label shaped like "word vectors 43%", already
    /// de-duplicated.
    func ensure(progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard !isCached else { return }
        try await underLock { try await fetch(progress: progress) }
    }

    private func underLock(_ body: () async throws -> Void) async throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let handle = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { throw Failure.busy(label) }
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy(label) }
        try await body()
    }

    /// Fetches into a staging directory and moves the result into place, so a
    /// half-written cache never loads. Staging sits inside `directory` to keep
    /// the move a rename on one volume.
    private func fetch(progress: (@Sendable (String) -> Void)?) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let left = try? manager.contentsOfDirectory(atPath: directory.path)
        for name in left ?? [] where name.hasPrefix(".staging-") {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
        let staging = directory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let reported = Reported()
        let label = label
        try await HubDownload.fetch(repo: repository, revision: revision, paths: files, into: staging) { fraction in
            guard let progress else { return }
            let percent = Int((fraction * 100).rounded())
            guard reported.advanced(to: percent) else { return }
            progress("\(label) \(percent)%")
        }
        for name in files {
            let target = directory.appendingPathComponent(name)
            try? manager.removeItem(at: target)
            try manager.moveItem(at: staging.appendingPathComponent(name), to: target)
        }
    }

    /// The percentage last reported. A class because the progress closure is
    /// `@Sendable` and escapes.
    private final class Reported: @unchecked Sendable {
        private var last = -1
        private let lock = NSLock()

        func advanced(to percent: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard percent > last else { return false }
            last = percent
            return true
        }
    }
}

/// `AutoTokenizer` over a folder, as the one protocol `loadModel` needs.
///
/// `MLXHuggingFace` provides this behind a macro, and swift-syntax with it.
/// This is the whole of what that macro expands to for the loading path.
@available(macOS 14, *)
struct FolderTokenizer: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Adapter(try await AutoTokenizer.from(modelFolder: directory))
    }

    private struct Adapter: MLXLMCommon.Tokenizer, @unchecked Sendable {
        let upstream: any Tokenizers.Tokenizer

        init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            // Nothing here holds a conversation. One stage sends a sentence and
            // reads the states back; the other scores a sequence it built.
            []
        }
    }
}
