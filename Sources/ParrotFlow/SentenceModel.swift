import CoreML
import Foundation

/// ModernBERT, fetched on the first English dictation and kept.
///
/// Nothing reads it yet. It is here so the download happens once, early, and
/// out of the way of the sentence that triggered it — the model is 300 MB and
/// the first Core ML compile of it costs about 7 seconds, and neither is a
/// thing to discover on the dictation that needs it.
///
/// What it is for: a masked word probe over a ±12-word window, which repairs a
/// sentence a pause cut in two. Measured at about 8 ms per call at sequence
/// length 64, which is the only length this conversion is faithful at.
///
/// `znaat/modernbert-coreml` and not `finnvoorhees/ModernBERT-CoreML`. That one
/// is traced at a single token, where ModernBERT's sliding-window mask is
/// optimised away, and past that length its answers are noise — "The capital of
/// Ireland is [MASK]" comes back "£, isation, organisation".
@available(macOS 14, *)
actor SentenceModel {

    static let shared = SentenceModel()

    /// The row the setup screen draws for it. The peak is not the size on
    /// disk: the 299 MB package and the 288 MB compile of it both exist until
    /// the compile finishes.
    static let download = ModelDownload(
        id: "sentence", name: "ModernBERT", megabytes: 288, peak: 600,
        group: .language, blocking: false
    )

    private static let repository = "znaat/modernbert-coreml"
    private static let packageName = "ModernBERT-base-64.mlpackage"

    private static var files: [String] {
        [
            "\(packageName)/Manifest.json",
            "\(packageName)/Data/com.apple.CoreML/model.mlmodel",
            "\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
            // Nothing reads it yet either. It belongs with the weights it was
            // trained against, and fetching it now means the stage that needs
            // it needs no download of its own.
            "tokenizer.json",
        ]
    }

    static var directory: URL {
        AppVariant.supportDirectory
            .appendingPathComponent("models/modernbert-base-64", isDirectory: true)
    }

    /// The compiled form, which is what gets kept. The `.mlpackage` it was
    /// built from is deleted after the compile: it is another 299 MB, and a
    /// cache that will not load is re-fetched rather than rebuilt.
    static var compiledURL: URL {
        directory.appendingPathComponent("ModernBERT-base-64.mlmodelc", isDirectory: true)
    }

    static var tokenizerURL: URL {
        directory.appendingPathComponent("tokenizer.json")
    }

    /// Beside the cache directory, not inside it, so a fetch that deletes the
    /// cache does not delete the lock somebody is holding.
    private static var lockURL: URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent("modernbert-base-64.lock")
    }

    enum Failure: LocalizedError {
        case busy

        var errorDescription: String? {
            "another ParrotFlow process is fetching the sentence model"
        }
    }

    /// What `MLModel.compileModel` writes, checked before the model is loaded.
    ///
    /// Not belt and braces. A compiled model missing `model.mil` segfaults
    /// inside CoreML's `makeProgramWithMemoryLayout` rather than throwing, so
    /// the `catch` below cannot recover from a damaged cache — only this can.
    private static let compiledParts = ["model.mil", "coremldata.bin", "weights/weight.bin"]

    static var isCached: Bool {
        let files = FileManager.default
        return files.fileExists(atPath: tokenizerURL.path)
            && compiledParts.allSatisfy {
                files.fileExists(atPath: compiledURL.appendingPathComponent($0).path)
            }
    }

    private var model: MLModel?

    /// The fetch in flight, if any. Same reason as `Transcriber.loadingModels`:
    /// actor isolation stops a torn read of `model`, not two callers both
    /// finding it nil on either side of the same `await`.
    private var loading: Task<MLModel, Error>?

    /// Downloads, compiles and loads, or returns what is already loaded.
    ///
    /// `progress` gets a label shaped like "sentence model 43%", already
    /// de-duplicated — the handler behind it fires far more often than the
    /// number changes.
    @discardableResult
    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws -> MLModel {
        if let model { return model }
        if let loading { return try await loading.value }

        let task = Task<MLModel, Error> {
            try await Self.build(progress: progress)
        }
        loading = task
        defer { loading = nil }
        do {
            let loaded = try await task.value
            model = loaded
            ModelDownloads.report(Self.download.id, .installed)
            return loaded
        } catch {
            ModelDownloads.report(
                Self.download.id,
                .failed(ModelDownloads.failure(error, needs: Self.download.peakLabel))
            )
            throw error
        }
    }

    private static func build(
        progress: (@Sendable (String) -> Void)?
    ) async throws -> MLModel {
        if isCached {
            do { return try load() } catch {
                Log.write(
                    "sentence model: the cached copy will not load"
                        + " (\(error.localizedDescription)); fetching it again"
                )
            }
        }
        try await underLock { try await fetch(progress: progress) }
        return try load()
    }

    /// One process at a time inside `fetch`.
    ///
    /// The app and `--sentence-model` share this cache, and the second one in
    /// would delete the first one's staging directory mid-download. It does
    /// not wait for the lock: this is background work, and the next English
    /// dictation asks again.
    private static func underLock(_ body: () async throws -> Void) async throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let handle = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { throw Failure.busy }
        // Closing the descriptor releases the lock, and the kernel closes it
        // for a process that dies holding one.
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        try await body()
    }

    private static func load() throws -> MLModel {
        try MLModel(contentsOf: compiledURL)
    }

    private var tokenizers: [URL: BPETokenizer] = [:]

    /// Parsed once per file. Reading the 2 MB `tokenizer.json` and building its
    /// two 50k tables costs about 90 ms, against 8 ms for the forward pass the
    /// caller wanted, so a caller loading a probe per sentence would spend the
    /// whole budget here. Keyed by URL because `PARROTFLOW_TOKENIZER` points
    /// the check script at another copy.
    func tokenizer(at url: URL) throws -> BPETokenizer {
        if let cached = tokenizers[url] { return cached }
        let loaded = try BPETokenizer.load(contentsOf: url)
        tokenizers[url] = loaded
        return loaded
    }

    /// Fetches into a staging directory, compiles, then moves the result into
    /// place. Staging sits inside `directory` so the move is a rename on the
    /// same volume — across volumes `moveItem` copies, and a copy is not
    /// atomic. Half a cache that loads and answers nonsense is the failure
    /// this whole shape exists to prevent.
    private static func fetch(progress: (@Sendable (String) -> Void)?) async throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // A process that quits mid-download leaves its staging directory and
        // whatever it had fetched, which is up to 299 MB nothing will ever
        // read. Safe to delete every one of them because `underLock` means no
        // other process is fetching.
        let left = try? files.contentsOfDirectory(atPath: directory.path)
        for name in left ?? [] where name.hasPrefix(".staging-") {
            try? files.removeItem(at: directory.appendingPathComponent(name))
        }
        let staging = directory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        let reported = Reported()
        ModelDownloads.report(download.id, .downloading(percent: nil))
        try await HubDownload.fetch(
            repo: repository, paths: Self.files, into: staging
        ) { fraction in
            let percent = Int((fraction * 100).rounded())
            guard reported.advanced(to: percent) else { return }
            ModelDownloads.report(download.id, .downloading(percent: percent))
            progress?("sentence model \(percent)%")
        }

        let compiled = try await MLModel.compileModel(
            at: staging.appendingPathComponent(packageName)
        )
        defer { try? files.removeItem(at: compiled) }

        // The tokenizer first and the compiled model last, so `isCached` only
        // ever answers true for a pair that is both there.
        try? files.removeItem(at: tokenizerURL)
        try files.moveItem(at: staging.appendingPathComponent("tokenizer.json"), to: tokenizerURL)
        try? files.removeItem(at: compiledURL)
        try files.moveItem(at: compiled, to: compiledURL)
    }

    /// The percentage last reported. A class rather than a captured `var`
    /// because the progress closure is `@Sendable` and escapes.
    private final class Reported: @unchecked Sendable {
        private var last = -1
        private let lock = NSLock()

        func advanced(to percent: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard percent != last else { return false }
            last = percent
            return true
        }
    }
}
