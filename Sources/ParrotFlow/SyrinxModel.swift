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
        case unpublished

        var errorDescription: String? {
            switch self {
            case .busy: return "another ParrotFlow process is fetching the parser"
            case .damaged(let file): return "the parser cache is damaged: \(file)"
            case .unpublished: return "the parser has no published revision yet"
            }
        }
    }

    private static let repository = "znaat/parrot-syrinx-coreml"
    /// Nil until the model is published.
    static let revision: String? = nil
    private static let packageName = "parrot-syrinx.mlpackage"

    private static let pinned: [String: String] = [
        "\(packageName)/Manifest.json": "0a17227b61be34f337598d3aed394179165e6528e458358a4226f84f49547574",
        "\(packageName)/Data/com.apple.CoreML/model.mlmodel": "9c69fbe3e85c338154d5e1ab9e5e7758e4b6efc2d0a5871e84b1a35018ca1c62",
        "\(packageName)/Data/com.apple.CoreML/weights/weight.bin": "2df7b948ee285b49281f9a7170357ccaef367cf1ba24036e861dfe8d82d210a7",
        "syrinx.safetensors": "9b7396778657b8ce59cc659a756d9e0df429f86f2a00059fb22c25ef49890e24",
        "tokenizer.json": "197d4cc5406ee12cc50c8b5511f2393cc32d9db321545979ce041c1199178356",
    ]
    private static let kept = ["syrinx.safetensors", "tokenizer.json"]

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

    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws -> Parser {
        if let parser { return parser }
        if let loading { return try await loading.value }
        let task = Task<Parser, Error> { try await Self.build(progress: progress) }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        parser = loaded
        return loaded
    }

    private static func build(progress: (@Sendable (String) -> Void)?) async throws -> Parser {
        if isCached {
            do { return try load() } catch {
                Log.write("parser: the cached copy will not load (\(error.localizedDescription)); fetching it again")
                progress?("\(error.localizedDescription); fetching it again")
            }
        }
        let mirror = ProcessInfo.processInfo.environment["PARROTFLOW_HUB_ENDPOINT"] != nil
        guard let revision = revision ?? (mirror ? "main" : nil) else { throw Failure.unpublished }
        try await underLock { try await fetch(revision: revision, progress: progress) }
        return try load()
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
        let data = try Data(contentsOf: digestsURL)
        let digests = try JSONDecoder().decode([String: String].self, from: data)
        guard !digests.isEmpty else { throw Failure.damaged("digests.json") }
        for (path, digest) in digests.sorted(by: { $0.key < $1.key }) {
            guard (try? sha256(directory.appendingPathComponent(path))) == digest else {
                throw Failure.damaged(path)
            }
        }
    }

    private static func underLock(_ body: () async throws -> Void) async throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let handle = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { throw Failure.busy }
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        try await body()
    }

    private static func fetch(revision: String, progress: (@Sendable (String) -> Void)?) async throws {
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
            repo: repository, revision: revision, paths: pinned.keys.sorted(), into: staging
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

        var digests: [String: String] = [:]
        for name in kept { digests[name] = try sha256(directory.appendingPathComponent(name)) }
        let base = directory.standardizedFileURL.path + "/"
        let walk = files.enumerator(at: compiledURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walk?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            digests[String(url.standardizedFileURL.path.dropFirst(base.count))] = try sha256(url)
        }
        try JSONEncoder().encode(digests).write(to: digestsURL, options: .atomic)
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
