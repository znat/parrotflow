import FluidAudio
import Foundation

/// One JSON object per dictation, appended to `trace.jsonl` beside the
/// recordings it describes.
///
/// `ParrotFlow.log` is for reading over someone's shoulder while something is
/// going wrong: prose, second resolution, and a rolling buffer that throws the
/// oldest away. That makes it the wrong place to keep what the decoder
/// actually said. The interesting questions here are asked over hundreds of
/// dictations at once — which words does the model get least sure about, does
/// a dropped ending come from the decoder or the speech gate, what does a
/// prompt stage really cost — and none of them survive a file that truncates
/// itself, or a format you have to parse back out of English.
///
/// So: one line per dictation, never rotated, joined to its audio by
/// `wav`. The decoder already computes every number in here and we used to
/// drop it on the floor one line after it arrived.
///
/// Collected through a task local rather than an extra parameter on nine
/// functions. A dictation is one task from the decoder to the last pipeline
/// stage, which is exactly the scope a task local has; the alternative was
/// threading a collector through `Pipeline.run`, `apply` and `runPrompt` for
/// the sake of a debug artefact.
enum Trace {

    /// The dictation being traced right now, if any. Nil on every path that
    /// did not ask for a trace — nothing here runs unless a collector is bound.
    @TaskLocal static var current: Collector?

    /// Where a trace comes from, so a sweep re-run over the archive can be told
    /// apart from the dictations someone actually spoke.
    enum Source: String {
        case live
        case cli
    }

    // MARK: - Collecting

    /// Gathers one dictation's record as it happens.
    ///
    /// A class with a lock rather than an actor: every writer here is a
    /// synchronous call sitting next to an existing `Log.write`, and making
    /// them all `await` would have been the whole invasive change again.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()

        private let wav: String
        private let source: Source
        private var asr: ASR?
        private var vad: VAD?
        private var stages: [Stage] = []
        private var final: String?

        init(wav: String, source: Source) {
            self.wav = wav
            self.source = source
        }

        func recordASR(_ result: ASRResult) {
            lock.lock(); defer { lock.unlock() }
            asr = ASR(
                text: result.text,
                confidence: result.confidence,
                duration: result.duration,
                processing: result.processingTime,
                words: Trace.words(from: result.tokenTimings ?? [])
            )
        }

        func recordVAD(speech: Double, total: Double, segments: [(Double, Double)]) {
            lock.lock(); defer { lock.unlock() }
            vad = VAD(
                speech: speech, total: total,
                segments: segments.map { [$0.0, $0.1] }
            )
        }

        func recordSkip(_ name: String, reason: String) {
            lock.lock(); defer { lock.unlock() }
            stages.append(Stage(name: name, skipped: reason))
        }

        /// Every stage that ran, including the ones that changed nothing —
        /// "ran and found nothing" and "was skipped" are different answers and
        /// only the log conflates them.
        func recordStage(_ name: String, before: String, after: String, seconds: Double) {
            lock.lock(); defer { lock.unlock() }
            stages.append(
                Stage(name: name, before: before, after: after, seconds: seconds)
            )
        }

        /// What was actually delivered. Left nil by a dictation that threw on
        /// the way there, which is worth being able to see.
        func recordFinal(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            final = text
        }

        fileprivate func record(at: String, app: String?) -> Record {
            lock.lock(); defer { lock.unlock() }
            return Record(
                at: at, wav: wav, source: source.rawValue, app: app,
                asr: asr, vad: vad, stages: stages, final: final
            )
        }
    }

    // MARK: - Writing

    /// Runs `body` with a collector bound, then appends what it gathered.
    ///
    /// Writes the line whether or not the body threw: a dictation that failed
    /// halfway is the one you most want the decoder's numbers for.
    static func record<T>(
        wav: String, source: Source, app: String? = nil,
        body: () async throws -> T
    ) async rethrows -> T {
        let collector = Collector(wav: wav, source: source)
        defer { append(collector.record(at: stamp(), app: app)) }
        return try await $current.withValue(collector) { try await body() }
    }

    private static let queue = DispatchQueue(label: "com.parrotflow.trace")

    /// Waits for queued writes to reach the file. Same reason as `Log.flush` —
    /// a CLI process exits before the queue drains.
    static func flush() {
        queue.sync {}
    }

    /// Where `trace.jsonl` goes — the recordings directory, so a clip and its
    /// trace live together. Set from the config at launch, because the stages
    /// that write here are handed a transcript and nothing else.
    nonisolated(unsafe) static var directory: URL?

    private static func append(_ record: Record) {
        guard let directory else { return }
        let url = directory.appendingPathComponent("trace.jsonl")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)  // one object per line, so `jq -c` and friends work

        queue.async {
            let fm = FileManager.default
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Deliberately no size cap. This is the corpus, not a debug
                // buffer: a year of heavy use is a few megabytes, and the whole
                // point is being able to ask a question of every dictation you
                // have ever given.
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Words

    /// Sub-word tokens grouped into words, keeping the confidence FluidAudio's
    /// own `buildWordTimings` drops.
    ///
    /// Confidence is the reason this file exists — a word the decoder was
    /// unsure of is a candidate for `transcription.replacements`, and ranking
    /// those beats guessing at them. The word keeps its *lowest* token's
    /// confidence: a name that came through as one solid piece and one shaky
    /// one is a shaky name, and averaging hides exactly that.
    static func words(from timings: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var confidence = Float.greatestFiniteMagnitude

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            words.append(
                Word(word: trimmed, start: start, end: end, confidence: confidence)
            )
        }

        for timing in timings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }

            // SentencePiece marks a word's first piece with `▁`; the tokenizer
            // hands some of them back already rendered as a leading space.
            if token.hasPrefix("\u{2581}") || token.hasPrefix(" ") || text.isEmpty {
                if !text.isEmpty { flush() }
                text = token.replacingOccurrences(of: "\u{2581}", with: "")
                start = timing.startTime
                confidence = timing.confidence
            } else {
                text += token
                confidence = min(confidence, timing.confidence)
            }
            end = timing.endTime
        }
        flush()
        return words
    }

    // MARK: - Shape on disk

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    fileprivate struct Record: Encodable {
        let at: String
        let wav: String
        let source: String
        let app: String?
        let asr: ASR?
        let vad: VAD?
        let stages: [Stage]
        let final: String?
    }

    fileprivate struct ASR: Encodable {
        let text: String
        let confidence: Float
        let duration: Double
        let processing: Double
        let words: [Word]
    }

    fileprivate struct VAD: Encodable {
        let speech: Double
        let total: Double
        let segments: [[Double]]
    }

    struct Word: Encodable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Float
    }

    fileprivate struct Stage: Encodable {
        let name: String
        var skipped: String?
        var before: String?
        var after: String?
        var seconds: Double?

        init(name: String, skipped: String) {
            self.name = name
            self.skipped = skipped
        }

        init(name: String, before: String, after: String, seconds: Double) {
            self.name = name
            self.before = before
            self.after = after
            self.seconds = seconds
        }
    }
}
