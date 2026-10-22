import CoreML
import CryptoKit
import Foundation

/// Every load hashes the cache against `digests.json`: a flipped byte in
/// `weight.bin` loads without error and changes the numbers.
actor SyrinxModel {

    static let shared = SyrinxModel()

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

    private static let repository = "znaat/parrotflow-syrinx-coreml"
    static let revision = "f3f75830f56901b45069df3492ade0040a6e2e39"
    private static let packageName = "parrotflow-syrinx.mlpackage"

    private static let pinned: [String: String] = [
        "cut-filter.safetensors": "b6746f9082ba881031ab4b298d255823521f4ea7e31dd29ec4be6e17249086a9",
        "\(packageName)/Manifest.json": "92723dd897adbc78eb6aa4c793decb8fe4dcc6be2f8653eb11a45cf42f8d0a6f",
        "\(packageName)/Data/com.apple.CoreML/model.mlmodel": "12b318dc69411d3f1dfdc865583a24d5ab8d1f8d39c4a874e91ef8ee875d2c9d",
        "\(packageName)/Data/com.apple.CoreML/weights/weight.bin": "f23f2bbb731edd4786445c900b1c84f0ee2e9ddd8b69425341ac5033c4362f44",
        "syrinx.safetensors": "da6385895a409154077179fe0269c7cae92effee4d779e822f9412a6b0534045",
        "tokenizer.json": "197d4cc5406ee12cc50c8b5511f2393cc32d9db321545979ce041c1199178356",
    ]
    private static let kept = ["cut-filter.safetensors", "syrinx.safetensors", "tokenizer.json"]

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
        AppVariant.supportDirectory.appendingPathComponent("models/parrotflow-syrinx", isDirectory: true)
    }

    static var compiledURL: URL {
        directory.appendingPathComponent("parrotflow-syrinx.mlmodelc", isDirectory: true)
    }

    private static var digestsURL: URL { directory.appendingPathComponent("digests.json") }

    private static var lockURL: URL {
        directory.deletingLastPathComponent().appendingPathComponent("parrotflow-syrinx.lock")
    }

    static var isCached: Bool { FileManager.default.fileExists(atPath: digestsURL.path) }

    struct Loaded: Sendable {
        let parser: Parser
        let cutFilter: CutFilter
    }

    private var loaded: Loaded?
    private var loading: Task<Loaded, Error>?

    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws -> Loaded {
        if let loaded { return loaded }
        if let loading { return try await loading.value }
        let task = Task<Loaded, Error> { try await Self.build(progress: progress) }
        loading = task
        defer { loading = nil }
        let built = try await task.value
        loaded = built
        return built
    }

    private static func build(progress: (@Sendable (String) -> Void)?) async throws -> Loaded {
        if isCached {
            do { return try load() } catch Failure.busy { throw Failure.busy } catch {
                Log.write("parser: the cached copy will not load (\(error.localizedDescription)); fetching it again")
                progress?("\(error.localizedDescription); fetching it again")
            }
        }
        let handle = try lock(LOCK_EX)
        defer { close(handle) }
        try await fetch(progress: progress)
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

    private static func load() throws -> Loaded {
        let handle = try lock(LOCK_SH)
        defer { close(handle) }
        return try openCache()
    }

    /// Callers hold the lock, shared or exclusive.
    private static func openCache() throws -> Loaded {
        try verify()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        let tokenizer = try ScalarBPE(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        let parser = try Parser(
            model: model, tokenizer: tokenizer,
            weights: directory.appendingPathComponent("syrinx.safetensors")
        )
        let filter = try CutFilter(contentsOf: directory.appendingPathComponent("cut-filter.safetensors"))
        return Loaded(parser: parser, cutFilter: filter)
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
            if reported.advanced(to: percent) { progress?("parser \(percent)%") }
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
