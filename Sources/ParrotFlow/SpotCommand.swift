import AVFoundation
import FluidAudio
import Foundation

/// `--spot <file.wav>` — runs *only* the CTC keyword spotter and prints its raw
/// detections with scores.
///
/// This isolates the two halves of context biasing. If the spotter reports
/// detections but the transcript is unchanged, the rescorer is rejecting them.
/// If the spotter reports nothing, the problem is upstream and no amount of
/// rescorer tuning will help.
/// Mutable box so the detached task can report back without capturing a var.
private final class Outcome: @unchecked Sendable {
    var code: Int32 = 0
}

@available(macOS 14, *)
enum SpotCommand {

    static func run(path: String, minScore: Float?) -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("✗ no such file: \(url.path)")
            return 1
        }

        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        let terms = config.transcription.vocabulary
        guard !terms.isEmpty else {
            print("✗ no vocabulary terms configured")
            return 1
        }

        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let names = terms.map(\.text).joined(separator: ", ")
        let threshold = minScore

        Task<Void, Never> {
            do {
                let samples = try loadSamples(url: url)
                let seconds = Double(samples.count) / 16000
                print("audio: \(samples.count) samples, \(String(format: "%.2f", seconds))s @16k")
                print("terms: \(names)")
                let shown: String = threshold.map { String($0) } ?? "default (-15.0)"
                print("minScore: \(shown)\n")

                let ctcModels = try await CtcModels.downloadAndLoad()
                let spotter = CtcKeywordSpotter(models: ctcModels)
                let tokenizer = try await CtcTokenizer.load(
                    from: CtcModels.defaultCacheDirectory(for: .ctc110m)
                )
                let vocabTerms = Transcriber.tokenize(terms, using: tokenizer)
                for term in vocabTerms {
                    print("  tokenized \(term.text) -> \(term.ctcTokenIds ?? [])")
                }
                let vocabulary = CustomVocabularyContext(terms: vocabTerms)

                let result = try await spotter.spotKeywordsWithLogProbs(
                    audioSamples: samples,
                    customVocabulary: vocabulary,
                    minScore: threshold
                )

                let frameMs = String(format: "%.4f", result.frameDuration)
                print("frames: \(result.totalFrames), frameDuration: \(frameMs)s")
                print("detections: \(result.detections.count)")

                for detection in result.detections {
                    let name = detection.term.text
                    let score = String(format: "%.3f", Double(detection.score))
                    let from = String(format: "%.2f", detection.startTime)
                    let to = String(format: "%.2f", detection.endTime)
                    print("  \(name)  score \(score)  \(from)s-\(to)s")
                }
                if result.detections.isEmpty {
                    print("  (none - no acoustic support found for any term)")
                    outcome.code = 1
                }
            } catch {
                print("error: \(error.localizedDescription)")
                outcome.code = 1
            }
            done.signal()
        }

        done.wait()
        return outcome.code
    }

    /// Parakeet wants a flat 16 kHz mono Float32 array.
    private static func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }
        try file.read(into: buffer)

        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
