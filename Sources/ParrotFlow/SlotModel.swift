import CoreML
import Foundation

/// mmBERT-small, fetched on the first English dictation and kept.
///
/// What it is for: the masked slot the vocabulary gate reads. `SlotReference`
/// asks it for the ten words a position expects, and `SlotGate` asks it what
/// part of speech those words are. Both run over `SlotProbe`.
///
/// **Why not ModernBERT, which is already here.** ModernBERT is English-only,
/// so the whole vocabulary gate is English-only. mmBERT-small covers 1,800
/// languages and ties it on the English bench — 192/238 each at the shipped
/// floor, AUC 0.888 against 0.887. That is what makes a French gate possible,
/// and it is the whole reason for the swap.
///
/// It is not cheaper. The weights are 282 MB against ModernBERT's 299, but the
/// tokenizer is 18 MB against 2, so the cache is the same size. A forward pass
/// is 18 ms against 11: the 256,000-word head is five times ModernBERT's, and
/// that is where the time goes.
///
/// **It was not given the boundary job.** mmBERT loses that one badly — 59% of
/// spurious breaks repaired against ModernBERT's 83%, three quarters of the loss
/// in the `P(".")` term alone. It does not know where an English sentence ends.
/// That stage reads Qwen now, and ModernBERT has left the app.
///
/// The weights are fp16, which is what `ct.convert` writes for an ML program by
/// default. Against the fp32 PyTorch model on the 238-case bench it changes no
/// decision, and the gaps agree to 0.031.
///
@available(macOS 14, *)
actor SlotModel {

    static let shared = SlotModel()

    private static let repository = "znaat/mmbert-small-coreml"
    /// Pinned, not `main`. The tokenizer fixture in `tests/` is the answer for
    /// one `tokenizer.json`, and the gap cases are the answer for one set of
    /// weights, so a new upload has to be adopted deliberately.
    private static let revision = "a983542a6ae292d0147cbdb9b54eddd00c4f6001"
    private static let packageName = "mmBERT-small-64.mlpackage"

    private static var files: [String] {
        [
            "\(packageName)/Manifest.json",
            "\(packageName)/Data/com.apple.CoreML/model.mlmodel",
            "\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
            // The three `AutoTokenizer.from(modelFolder:)` reads. It wants
            // `config.json` and `tokenizer_config.json` beside `tokenizer.json`
            // and throws without them, which is why this repository holds two
            // files `znaat/modernbert-coreml` does not.
            "tokenizer.json",
            "tokenizer_config.json",
            "config.json",
        ]
    }

    static var directory: URL {
        AppVariant.supportDirectory
            .appendingPathComponent("models/mmbert-small-64", isDirectory: true)
    }

    /// The compiled form, which is what gets kept. The `.mlpackage` it was
    /// built from is deleted after the compile: it is another 269 MB, and a
    /// cache that will not load is re-fetched rather than rebuilt.
    static var compiledURL: URL {
        directory.appendingPathComponent("mmBERT-small-64.mlmodelc", isDirectory: true)
    }

    /// The folder `AutoTokenizer` reads, which is the cache directory itself.
    /// `PARROTFLOW_SLOT_TOKENIZER` points the check script at a copy.
    static var tokenizerDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PARROTFLOW_SLOT_TOKENIZER"] {
            return URL(fileURLWithPath: path)
        }
        return directory
    }

    /// Beside the cache directory, not inside it, so a fetch that deletes the
    /// cache does not delete the lock somebody is holding.
    private static var lockURL: URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent("mmbert-small-64.lock")
    }

    enum Failure: LocalizedError {
        case busy

        var errorDescription: String? {
            "another ParrotFlow process is fetching the slot model"
        }
    }

    /// What `MLModel.compileModel` writes, checked before the model is loaded.
    ///
    /// Not belt and braces. A compiled model missing `model.mil` segfaults
    /// inside CoreML's `makeProgramWithMemoryLayout` rather than throwing, so
    /// the `catch` below cannot recover from a damaged cache — only this can.
    private static let compiledParts = ["model.mil", "coremldata.bin", "weights/weight.bin"]

    private static let tokenizerParts = ["tokenizer.json", "tokenizer_config.json", "config.json"]

    static var isCached: Bool {
        let files = FileManager.default
        return tokenizerParts.allSatisfy {
            files.fileExists(atPath: directory.appendingPathComponent($0).path)
        } && compiledParts.allSatisfy {
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
    /// `progress` gets a label shaped like "slot model 43%", already
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
        let loaded = try await task.value
        model = loaded
        return loaded
    }

    private static func build(
        progress: (@Sendable (String) -> Void)?
    ) async throws -> MLModel {
        if isCached {
            do { return try load() } catch {
                Log.write(
                    "slot model: the cached copy will not load"
                        + " (\(error.localizedDescription)); fetching it again"
                )
            }
        }
        try await underLock { try await fetch(progress: progress) }
        return try load()
    }

    /// One process at a time inside `fetch`.
    ///
    /// The app and `--slot-model` share this cache, and the second one in would
    /// delete the first one's staging directory mid-download. It does not wait
    /// for the lock: this is background work, and the next English dictation
    /// asks again.
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

    /// **`.cpuAndGPU`, not the default.** On the Neural Engine this model is not
    /// approximately right, it is wrong: 0 of 238 filler lists match PyTorch and
    /// the correlation at the mask falls to 0.156. Here it is 0.99999 and up.
    private static func load() throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    private var tokenizers: [URL: SlotTokenizer] = [:]

    /// Parsed once per folder. `tokenizer.json` is 33 MB and holds 256,000
    /// entries, so a caller loading a probe per sentence would spend the whole
    /// budget here. Keyed by folder because `PARROTFLOW_SLOT_TOKENIZER` points
    /// the check script at another copy.
    func tokenizer(at directory: URL) async throws -> SlotTokenizer {
        if let cached = tokenizers[directory] { return cached }
        let loaded = try await SlotTokenizer.load(from: directory)
        tokenizers[directory] = loaded
        return loaded
    }

    /// Fetches into a staging directory, compiles, then moves the result into
    /// place. Staging sits inside `directory` so the move is a rename on the
    /// same volume — across volumes `moveItem` copies, and a copy is not
    /// atomic. Half a cache that loads and answers nonsense is the failure this
    /// whole shape exists to prevent.
    private static func fetch(progress: (@Sendable (String) -> Void)?) async throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // A process that quits mid-download leaves its staging directory and
        // whatever it had fetched, which is up to 269 MB nothing will ever
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
        try await HubDownload.fetch(
            repo: repository, revision: revision, paths: Self.files, into: staging
        ) { fraction in
            guard let progress else { return }
            let percent = Int((fraction * 100).rounded())
            guard reported.advanced(to: percent) else { return }
            progress("slot model \(percent)%")
        }

        let compiled = try await MLModel.compileModel(
            at: staging.appendingPathComponent(packageName)
        )
        defer { try? files.removeItem(at: compiled) }

        // The tokenizer files first and the compiled model last, so `isCached`
        // only ever answers true for a set that is all there.
        for name in tokenizerParts {
            let destination = directory.appendingPathComponent(name)
            try? files.removeItem(at: destination)
            try files.moveItem(at: staging.appendingPathComponent(name), to: destination)
        }
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
