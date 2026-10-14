import CoreML
import CryptoKit
import Foundation

/// Every load hashes the cache against `digests.json`: a flipped byte in
/// `weight.bin` loads without error and changes the numbers.
actor SyrinxModel {

    static let shared = SyrinxModel()

    /// The peak holds the package and its compile at once.
    static let download = ModelDownload(
        id: "parser", name: "parrot-syrinx", megabytes: 519, peak: 640,
        group: .language, blocking: false,
        costOfFailure: "\"I mean\", \"you know\" and \"like\" are left in"
    )

    enum Failure: LocalizedError {
        case busy
        case damaged(String)
        case stale

        var errorDescription: String? {
            switch self {
            case .busy: return "another ParrotFlow process is fetching the parser"
            case .damaged(let file): return "the parser cache is damaged: \(file)"
            case .stale: return "the parser cache is from another release"
            }
        }
    }

    private static let repository = "znaat/parrot-syrinx-coreml"
    static let revision = "6ef93ba322a66cb3fda0addde0dd8f541b97e3fb"
    private static let packageName = "parrot-syrinx.mlpackage"

    private static let pinned: [String: String] = [
        "\(packageName)/Manifest.json": "0a17227b61be34f337598d3aed394179165e6528e458358a4226f84f49547574",
        "\(packageName)/Data/com.apple.CoreML/model.mlmodel": "9c69fbe3e85c338154d5e1ab9e5e7758e4b6efc2d0a5871e84b1a35018ca1c62",
        "\(packageName)/Data/com.apple.CoreML/weights/weight.bin": "2df7b948ee285b49281f9a7170357ccaef367cf1ba24036e861dfe8d82d210a7",
        "syrinx.safetensors": "9b7396778657b8ce59cc659a756d9e0df429f86f2a00059fb22c25ef49890e24",
        "tokenizer.json": "197d4cc5406ee12cc50c8b5511f2393cc32d9db321545979ce041c1199178356",
    ]
    private static let kept = ["syrinx.safetensors", "tokenizer.json"]

    /// `PARROTFLOW_SYRINX_ENDPOINT` points this download, and no other, at a
    /// mirror for tests. What it serves must still match `pinned`.
    private static var endpoint: String {
        ProcessInfo.processInfo.environment["PARROTFLOW_SYRINX_ENDPOINT"] ?? HubDownload.huggingFace
    }

    /// `pinned` as it was when the cache was built, so a cache from another
    /// release is fetched again rather than verified against itself.
    private struct Digests: Codable {
        let pinned: [String: String]
        let files: [String: String]
    }

    static var directory: URL {
        AppVariant.supportDirectory.appendingPathComponent("models/parrot-syrinx", isDirectory: true)
    }

    static var compiledURL: URL {
        directory.appendingPathComponent("parrot-syrinx.mlmodelc", isDirectory: true)
    }

    private static var digestsURL: URL { directory.appendingPathComponent("digests.json") }

    private static var lockURL: URL {
        directory.deletingLastPathComponent().appendingPathComponent("parrot-syrinx.lock")
    }

    static var isCached: Bool { FileManager.default.fileExists(atPath: digestsURL.path) }

    private var parser: Parser?
    private var loading: Task<Parser, Error>?
    /// When a failed load may be tried again. A damaged cache re-fetches 519 MB, so not on every dictation.
    private var retryAfter: Date?
    private static let backoff: TimeInterval = 300

    /// The parser if it is in memory. A dictation never waits for it.
    var loaded: Parser? { parser }

    /// Starts the load if nothing is doing it, and returns at once.
    func warm() {
        guard parser == nil, loading == nil else { return }
        if let retryAfter, Date() < retryAfter { return }
        Task { [weak self] in
            let started = Date()
            do {
                _ = try await self?.prepare()
                Log.write(String(format: "parser: warmed in %.1fs", Date().timeIntervalSince(started)))
            } catch {
                await self?.hold(after: error)
            }
        }
    }

    /// Forgets the backoff and starts the load, for the setup screen's repair button.
    func retryNow() {
        retryAfter = nil
        warm()
    }

    private func hold(after error: Error) {
        retryAfter = Date().addingTimeInterval(Self.backoff)
        Log.write("parser: \(error.localizedDescription); word fillers stay until it loads")
    }

    static func discardCache() {
        try? FileManager.default.removeItem(at: directory)
    }

    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws -> Parser {
        if let parser { return parser }
        if let loading { return try await loading.value }
        let task = Task<Parser, Error> { try await Self.build(progress: progress) }
        loading = task
        defer { loading = nil }
        do {
            let loaded = try await task.value
            parser = loaded
            ModelDownloads.report(Self.download.id, .installed)
            return loaded
        } catch {
            ModelDownloads.report(
                Self.download.id, .failed(ModelDownloads.failure(error, needs: Self.download.peakLabel))
            )
            throw error
        }
    }

    /// Off the actor, so a dictation asking for `loaded` never waits on it.
    private static func build(progress: (@Sendable (String) -> Void)?) async throws -> Parser {
        let parser = try await openOrFetch(progress: progress)
        // The first prediction after a load took 167 to 223 ms against 10 to 16 ms warm.
        _ = parser.parse(words: Words(joining: ["I", "mean", "it"]), language: "en")
        return parser
    }

    private static func openOrFetch(progress: (@Sendable (String) -> Void)?) async throws -> Parser {
        if isCached {
            ModelDownloads.report(download.id, .loading)
            do { return try load() } catch Failure.busy { throw Failure.busy } catch {
                Log.write("parser: the cached copy will not load (\(error.localizedDescription)); fetching it again")
                progress?("\(error.localizedDescription); fetching it again")
            }
        }
        let handle = try lock(LOCK_EX)
        defer { close(handle) }
        try await fetch(progress: progress)
        ModelDownloads.report(download.id, .loading)
        return try openCache()
    }

    /// `.cpuAndGPU` is pinned because under `.all` the OS picks the device per
    /// shape and may pick the Neural Engine.
    static var computeUnits: MLComputeUnits {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PARROTFLOW_SYRINX_UNITS"] == "all" { return .all }
        #endif
        return .cpuAndGPU
    }

    private static func load() throws -> Parser {
        let handle = try lock(LOCK_SH)
        defer { close(handle) }
        return try openCache()
    }

    /// Callers hold the lock, shared or exclusive.
    private static func openCache() throws -> Parser {
        try verify()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        let tokenizer = try ScalarBPE(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        return try Parser(
            model: model, tokenizer: tokenizer,
            weights: directory.appendingPathComponent("syrinx.safetensors")
        )
    }

    /// Core ML segfaults on a compiled model missing `model.mil` rather than
    /// throwing.
    private static func verify() throws {
        guard let digests = try? JSONDecoder().decode(Digests.self, from: Data(contentsOf: digestsURL))
        else { throw Failure.damaged("digests.json") }
        guard digests.pinned == pinned else { throw Failure.stale }
        guard kept.allSatisfy({ digests.files[$0] == pinned[$0] }), digests.files.count > kept.count
        else { throw Failure.damaged("digests.json") }
        for (path, digest) in digests.files.sorted(by: { $0.key < $1.key }) {
            guard (try? sha256(directory.appendingPathComponent(path))) == digest else {
                throw Failure.damaged(path)
            }
        }
    }

    /// Shared to load, exclusive to fetch, so a load never verifies files a
    /// fetch is replacing. Never waits: the caller abstains and asks again.
    private static func lock(_ operation: Int32) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let handle = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { throw Failure.busy }
        guard flock(handle, operation | LOCK_NB) == 0 else {
            close(handle)
            throw Failure.busy
        }
        return handle
    }

    private static func fetch(progress: (@Sendable (String) -> Void)?) async throws {
        let files = FileManager.default
        try? files.removeItem(at: digestsURL)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(".staging-") {
            try? files.removeItem(at: directory.appendingPathComponent(name))
        }
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        let reported = Reported()
        try await HubDownload.fetch(
            repo: repository, revision: revision, paths: pinned.keys.sorted(), into: staging,
            endpoint: endpoint
        ) { fraction in
            let percent = Int((fraction * 100).rounded())
            guard reported.advanced(to: percent) else { return }
            ModelDownloads.report(download.id, .downloading(percent: percent))
            progress?("parser \(percent)%")
        }
        for (path, digest) in pinned where try sha256(staging.appendingPathComponent(path)) != digest {
            throw Failure.damaged("\(path) does not match its pinned SHA-256")
        }

        progress?("compiling the parser")
        let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent(packageName))
        defer { try? files.removeItem(at: compiled) }
        for name in kept {
            let destination = directory.appendingPathComponent(name)
            try? files.removeItem(at: destination)
            try files.moveItem(at: staging.appendingPathComponent(name), to: destination)
        }
        try? files.removeItem(at: compiledURL)
        try files.moveItem(at: compiled, to: compiledURL)

        var hashes: [String: String] = [:]
        for name in kept { hashes[name] = try sha256(directory.appendingPathComponent(name)) }
        let base = directory.standardizedFileURL.path + "/"
        let walk = files.enumerator(at: compiledURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walk?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hashes[String(url.standardizedFileURL.path.dropFirst(base.count))] = try sha256(url)
        }
        try JSONEncoder().encode(Digests(pinned: pinned, files: hashes)).write(to: digestsURL, options: .atomic)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Each block is autoreleased: without a pool per block, hashing the
        // 530 MB cache held all of it until the task ended.
        while try autoreleasepool(invoking: {
            guard let block = try handle.read(upToCount: 1 << 22), !block.isEmpty else { return false }
            hasher.update(data: block)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

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
