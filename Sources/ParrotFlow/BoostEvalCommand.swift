import AVFoundation
import FluidAudio
import Foundation

/// `--boost-eval [--shared-encoder] [--limit N]` — measures whether
/// vocabulary boosting is safe enough to turn on.
///
/// Every clip is transcribed twice, with boosting off and on, and the two are
/// compared. The vocabulary is the set of replacement targets, since those are
/// exactly the words worth boosting and they are already in the config.
///
/// The number that decides it is **damage**: clips containing none of the
/// vocabulary that come out different with boosting on. Recall is secondary —
/// replacements already deliver the names at zero damage, so boosting only
/// earns its place by being safe. An earlier attempt turned "Good morning."
/// into "Zylbersztejn", which is why this exists.
@available(macOS 14, *)
enum BoostEvalCommand {

    struct Case {
        let url: URL
        let baseline: String
        let hasTerm: Bool
    }

    static func run(sharedEncoder: Bool, limit: Int) -> Int32 {
        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        // Replacement targets are the vocabulary. Short terms are dropped:
        // they did the over-firing last time, and "Mik" is three characters.
        let terms = Set(config.transcription.replacements.values)
            .filter { $0.count >= 5 }
            .sorted()
        guard !terms.isEmpty else {
            print("✗ no replacement targets of 5+ characters to boost")
            return 1
        }

        let clips = Array(clipsWithBaselines().shuffled().prefix(limit))
        guard !clips.isEmpty else {
            print("✗ no clips with a known transcript")
            return 1
        }
        let positives = clips.filter(\.hasTerm).count

        print("vocabulary:   \(terms.joined(separator: ", "))")
        print("encoder:      \(sharedEncoder ? "tdtCtc110m (CTC and TDT share one)" : "parakeet v3 + separate CTC 110M")")
        print("clips:        \(clips.count)  (\(positives) contain a term, \(clips.count - positives) do not)")
        print("")

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            do { try await evaluate(clips: clips, terms: terms, sharedEncoder: sharedEncoder, config: config) }
            catch { print("✗ \(error.localizedDescription)"); code = 1 }
            done.signal()
        }
        done.wait()
        return code
    }

    private static func evaluate(
        clips: [Case], terms: [String], sharedEncoder: Bool, config: Config
    ) async throws {
        let version: AsrModelVersion = sharedEncoder ? .tdtCtc110m : .v3
        print("loading models…")
        let models = try await AsrModels.downloadAndLoad(version: version)
        let ctcModels = try await CtcModels.downloadAndLoad()
        let tokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: .ctc110m)
        )
        let vocabulary = CustomVocabularyContext(
            terms: terms.compactMap { term in
                let ids = tokenizer.encode(term)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
            }
        )
        print("ready.\n")

        var damaged: [(String, String, String)] = []
        var recovered = 0, missed = 0, unchangedPositives = 0

        for (index, clip) in clips.enumerated() {
            guard let samples = load(url: clip.url) else { continue }
            let off = try await transcribe(samples, models: models, vocabulary: nil, ctc: nil)
            let on = try await transcribe(samples, models: models, vocabulary: vocabulary, ctc: ctcModels)

            let changed = normalise(off) != normalise(on)
            if clip.hasTerm {
                if changed {
                    let gained = terms.contains { on.localizedCaseInsensitiveContains($0)
                        && !off.localizedCaseInsensitiveContains($0) }
                    if gained { recovered += 1 } else { damaged.append((clip.url.lastPathComponent, off, on)) }
                } else {
                    unchangedPositives += 1
                }
            } else if changed {
                damaged.append((clip.url.lastPathComponent, off, on))
                missed += 1
            }

            if (index + 1) % 10 == 0 {
                print("  \(index + 1)/\(clips.count)…")
            }
        }

        let positives = clips.filter(\.hasTerm).count
        let negatives = clips.count - positives
        print("\n── result ─────────────────────────────────")
        print("  recovered   \(recovered)/\(positives) positives improved")
        print("  unchanged   \(unchangedPositives)/\(positives) positives")
        print("  DAMAGE      \(missed)/\(negatives) negatives altered   <- must be 0")
        if !damaged.isEmpty {
            print("\n  changes:")
            for (name, off, on) in damaged.prefix(12) {
                print("    \(name)")
                print("      off: \(off.prefix(96))")
                print("      on:  \(on.prefix(96))")
            }
        }
        print("\n  verdict: \(missed == 0 && recovered > 0 ? "SAFE — worth enabling" : "NOT SAFE — leave boosting off")")
    }

    private static func transcribe(
        _ samples: [Float],
        models: AsrModels,
        vocabulary: CustomVocabularyContext?,
        ctc: CtcModels?
    ) async throws -> String {
        // A manager is single-use: finish() closes its input stream for good.
        let manager = SlidingWindowAsrManager(config: Transcriber.evaluationConfig)
        try await manager.loadModels(models)
        if let vocabulary, let ctc {
            try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctc)
        }
        try await manager.startStreaming(source: .microphone)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return "" }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        await manager.streamAudio(buffer)
        return try await manager.finish()
    }

    private static func load(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)
              ), (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clips paired with the transcript the log recorded for them, which was
    /// produced with boosting off and is therefore the baseline.
    private static func clipsWithBaselines() -> [Case] {
        guard let log = try? String(contentsOf: Log.fileURL, encoding: .utf8) else { return [] }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Recordings/ParrotFlow")

        let config = try? ConfigStore.load()
        let terms = Set((config?.transcription.replacements.values).map(Array.init) ?? [])

        var cases: [Case] = []
        var pending: String?
        for line in log.components(separatedBy: .newlines) {
            if let match = line.range(of: #"parrotflow-[\w\-T]+\.wav"#, options: .regularExpression) {
                pending = String(line[match])
            } else if let range = line.range(of: "transcribed: "), let file = pending {
                let text = String(line[range.upperBound...])
                let url = directory.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: url.path) {
                    cases.append(Case(
                        url: url,
                        baseline: text,
                        hasTerm: terms.contains { text.localizedCaseInsensitiveContains($0) }
                    ))
                }
                pending = nil
            }
        }
        return cases
    }
}
