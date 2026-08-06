import AVFoundation
import FluidAudio
import Foundation

/// `--spot <file.wav> [--terms "a,b"] [--from 0.5] [--to 1.5]` — shows what the
/// CTC pass actually returns, and what the keyword spotter makes of it.
///
/// Exists because "the scorer returns probabilities for the terms" is the
/// natural assumption and it is wrong. The CTC model knows nothing about the
/// vocabulary. It returns a grid — one row per 80 ms frame, one column per
/// sub-word token, about 1025 of them — and a term's score does not exist
/// until somebody aligns that term's tokens over a span and adds the numbers
/// up. That is the difference between the two ways a replacement gets
/// proposed, and this prints both:
///
///   1. The grid, as the top few tokens per frame. Nothing here is about your
///      vocabulary; it is what the audio sounded like.
///   2. The spotter's detections — where each term could be, found by aligning
///      it against that grid rather than by comparing spellings. This is what
///      the spotter-anchored path proposes from, and why it can reach a word
///      the string gate cannot.
@available(macOS 14, *)
enum SpotCommand {

    static func run(path: String, terms explicit: [String]?, from: Double?, to: Double?) -> Int32 {
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
        let wanted = explicit ?? config.vocabularyTerms.map(\.text)
        guard !wanted.isEmpty else {
            print("✗ no terms: pass --terms \"Praisy,Precy\"")
            return 1
        }

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            do { try await show(url: url, terms: wanted, from: from, to: to) }
            catch { print("✗ \(error.localizedDescription)"); code = 1 }
            done.signal()
        }
        done.wait()
        return code
    }

    private static func show(url: URL, terms: [String], from: Double?, to: Double?) async throws {
        guard let samples = Transcriber.samples(at: url) else {
            print("✗ not 16 kHz mono; re-record or convert")
            return
        }
        print("loading CTC…")
        let models = try await CtcModels.downloadAndLoad()
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: directory)

        // Every term is asked for by name. Note what goes in: token ids, not a
        // word — the spotter has no dictionary either.
        let built = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
        }
        let context = CustomVocabularyContext(terms: built)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let spotted = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples, customVocabulary: context, minScore: -20
        )
        guard !spotted.logProbs.isEmpty else {
            print("✗ the CTC pass returned nothing")
            return
        }

        let seconds = Double(samples.count) / Transcriber.sampleRate
        print(String(
            format: "\n%.2fs of audio, %d frames of %.0f ms, %d tokens per frame\n",
            seconds, spotted.totalFrames, spotted.frameDuration * 1000,
            spotted.logProbs.first?.count ?? 0
        ))

        print("── what the CTC returned ────────────────────────────────")
        print("   the grid, top 3 tokens per frame. No vocabulary involved.\n")
        // Clamped: `--from -1` is a legal number and an illegal frame index,
        // and subscripting the grid with it crashes rather than complaining.
        let start = max(0, Int((from ?? 0) / spotted.frameDuration))
        let end = min(spotted.logProbs.count, Int((to ?? seconds) / spotted.frameDuration))
        for frame in start..<max(start, end) {
            let row = spotted.logProbs[frame]
            // Blank wins nearly every frame — CTC emits it whenever nothing is
            // starting — and printing it hides the phonetic content underneath.
            // Its rank is shown instead, so a frame that is genuinely silent
            // still reads as silent.
            let blank = models.vocabulary.count
            let best = row.enumerated()
                .filter { $0.offset != blank }
                .sorted { $0.element > $1.element }.prefix(3)
            let cells = best.map { index, score -> String in
                let token = models.vocabulary[index].map { $0 == " " ? "␣" : $0 } ?? "<\(index)>"
                return String(format: "%@ %.1f", token, score)
            }
            let blankScore = row.indices.contains(blank) ? row[blank] : 0
            print(String(
                format: "   %5.2fs  %@   [blank %.1f]",
                Double(frame) * spotted.frameDuration,
                cells.joined(separator: "   "), blankScore
            ))
        }

        // The decoder's own words and their timings, so a detection can be
        // put where it lands. This is the reconciliation the rescue does with
        // `wordIndices(in:overlapping:end:)` before it proposes anything.
        let asrModels = try await AsrModels.downloadAndLoad()
        let asr = AsrManager(models: asrModels)
        var state = await TdtDecoderState.make(decoderLayers: asr.decoderLayerCount)
        let decoded = try await asr.transcribe(samples, decoderState: &state)
        let words = buildWordTimings(from: decoded.tokenTimings ?? [])
        print("\n── what the decoder wrote ───────────────────────────────\n")
        print("   \"\(decoded.text)\"\n")
        for word in words {
            print(String(format: "   %5.2f–%5.2fs  %@",
                         word.startTime, word.endTime, word.word as NSString))
        }

        print("\n── what the spotter returned ────────────────────────────")
        print("   each term aligned against that grid, wherever it fits best.")
        print("   This is what the spotter-anchored path proposes from — it")
        print("   never looks at what the decoder wrote.\n")
        if spotted.detections.isEmpty {
            print("   nothing above -20")
        }
        for detection in spotted.detections.sorted(by: { $0.score > $1.score }) {
            let hit = words.filter {
                $0.startTime < detection.endTime && $0.endTime > detection.startTime
            }.map(\.word).joined(separator: " ")
            // Two properties the score cannot express: how long the span is
            // per token, and how much of it is silence. A four-token word
            // spread over six seconds of pause is a legal CTC alignment and a
            // meaningless one — blanks between tokens are free, so a pause
            // dilutes the bad frames and flatters the per-token average.
            let tokens = max(1, detection.term.ctcTokenIds?.count ?? 1)
            let perToken = (detection.endTime - detection.startTime) / Double(tokens)
            let first = max(0, Int(detection.startTime / spotted.frameDuration))
            let last = min(spotted.logProbs.count, Int(detection.endTime / spotted.frameDuration))
            // Not "how often does blank win" — blank wins nearly every frame
            // even mid-speech, so that measured 100% on real words. What
            // separates speech from a pause is how good the best *non-blank*
            // token is: about -2 while somebody is talking, -9 to -13 in
            // silence. The median over the span is the honest summary.
            let blankIndex = models.vocabulary.count
            var loudness: [Float] = []
            for frame in first..<max(first, last) {
                let row = spotted.logProbs[frame]
                let best = row.enumerated()
                    .filter { $0.offset != blankIndex }
                    .map(\.element).max() ?? -50
                loudness.append(best)
            }
            let quiet = loudness.isEmpty
                ? Float(-50) : loudness.sorted()[loudness.count / 2]
            print(String(
                format: "   %-10@ %6.2f  %.2fs/token  speech %5.1f  -> %@",
                detection.term.text as NSString, detection.score,
                perToken, quiet,
                (hit.isEmpty ? "(no word)" : hit) as NSString
            ))
        }
        print("")
    }
}

/// `--spot-eval [--limit N] [--gate 0.35] [--per-token 0.5] [--speech -6]`
///
/// The spotter as a proposal source, over the whole archive, with the two
/// filters the score cannot express: how long a detection is per token, and
/// whether the span contains speech at all. Reports what it would propose and
/// how often, which are the two numbers that decide whether it can replace the
/// string-similarity path.
@available(macOS 14, *)
enum SpotEvalCommand {

    static func run(
        limit: Int, gate: Float, perToken: Double, speech: Float, casesPath: String? = nil
    ) -> Int32 {
        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }
        let terms = config.vocabularyTerms.map(\.text)
        guard !terms.isEmpty else { print("✗ no vocabulary terms"); return 1 }

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            do {
                try await measure(
                    config: config, terms: terms, limit: limit,
                    gate: gate, perToken: perToken, speech: speech, casesPath: casesPath
                )
            } catch { print("✗ \(error.localizedDescription)"); code = 1 }
            done.signal()
        }
        done.wait()
        return code
    }

    private static func measure(
        config: Config, terms: [String], limit: Int,
        gate: Float, perToken: Double, speech: Float, casesPath: String? = nil
    ) async throws {
        // Slots, not proposals. A span with three candidate terms is one
        // decision with four options — the word as heard, or one of the three
        // — and the options are what a judge needs to see. Flattening it into
        // three yes/no questions is what the shipped path does, and it is why
        // the judge is never told that `Mirza` and `Praisy` are competing for
        // the same half-second.
        struct Slot: Encodable {
            let heard: String
            let start: Double
            let end: Double
            var candidates: [String]
            var scores: [Float]
        }
        struct SlotCase: Encodable {
            let clip: String
            let said: String
            var slots: [Slot]
        }
        var slotCases: [SlotCase] = []
        let directory = config.resolvedOutputDir
        let clips = Array(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasPrefix("parrotflow-") && $0.hasSuffix(".wav") }
                .sorted().reversed().prefix(limit) ?? []
        )
        guard !clips.isEmpty else { print("✗ no recordings in \(directory.path)"); return }

        print("terms:   \(terms.joined(separator: ", "))")
        print("filters: <= \(perToken)s per token, speech >= \(speech), string gate \(gate)")
        print("clips:   \(clips.count)\n")

        let asrModels = try await AsrModels.downloadAndLoad()
        let asr = AsrManager(models: asrModels)
        let ctc = try await CtcModels.downloadAndLoad()
        let tokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let built = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
        }
        let context = CustomVocabularyContext(terms: built)
        let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
        let blankIndex = ctc.vocabulary.count

        var raw = 0, afterDuration = 0, afterSpeech = 0, afterGate = 0
        var census: [String: Int] = [:]
        var withProposals = 0

        for (index, name) in clips.enumerated() {
            let url = directory.appendingPathComponent(name)
            guard let samples = Transcriber.samples(at: url) else { continue }
            var state = await TdtDecoderState.make(decoderLayers: asr.decoderLayerCount)
            guard let decoded = try? await asr.transcribe(samples, decoderState: &state),
                  let timings = decoded.tokenTimings, !timings.isEmpty else { continue }
            let words = buildWordTimings(from: timings)
            guard let spotted = try? await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: context, minScore: -20
            ), !spotted.logProbs.isEmpty else { continue }

            var proposed = 0
            var slots: [String: Slot] = [:]
            for detection in spotted.detections {
                raw += 1
                let tokens = max(1, detection.term.ctcTokenIds?.count ?? 1)
                let seconds = (detection.endTime - detection.startTime) / Double(tokens)
                guard seconds <= perToken else { continue }
                afterDuration += 1

                let first = max(0, Int(detection.startTime / spotted.frameDuration))
                let last = min(spotted.logProbs.count,
                               Int(detection.endTime / spotted.frameDuration))
                var loudness: [Float] = []
                for frame in first..<max(first, last) {
                    let row = spotted.logProbs[frame]
                    loudness.append(row.enumerated().filter { $0.offset != blankIndex }
                        .map(\.element).max() ?? -50)
                }
                let quiet = loudness.isEmpty ? Float(-50) : loudness.sorted()[loudness.count / 2]
                guard quiet >= speech else { continue }
                afterSpeech += 1

                let span = words.filter {
                    $0.startTime < detection.endTime && $0.endTime > detection.startTime
                }
                guard !span.isEmpty, span.count <= 4 else { continue }
                let phrase = span.map(\.word).joined(separator: " ")
                let heard = phrase.lowercased()
                    .replacingOccurrences(of: " ", with: "")
                    .trimmingCharacters(in: .punctuationCharacters)
                let target = detection.term.text.lowercased()
                guard heard != target else { continue }
                guard Self.similarity(heard, target) >= gate else { continue }
                afterGate += 1
                proposed += 1
                census["\(phrase) -> \(detection.term.text)", default: 0] += 1

                let key = "\(span.first!.startTime)-\(span.last!.endTime)"
                if slots[key] == nil {
                    slots[key] = Slot(
                        heard: phrase, start: span.first!.startTime,
                        end: span.last!.endTime, candidates: [], scores: []
                    )
                }
                if !(slots[key]!.candidates.contains(detection.term.text)) {
                    slots[key]!.candidates.append(detection.term.text)
                    slots[key]!.scores.append(detection.score)
                }
            }
            if proposed > 0 {
                withProposals += 1
                slotCases.append(SlotCase(
                    clip: name, said: decoded.text,
                    slots: slots.values.sorted { $0.start < $1.start }
                ))
            }
            if (index + 1) % 25 == 0 { print("  \(index + 1)/\(clips.count)…") }
        }

        print("\n── what survives each filter ──────────────────────────")
        print("  raw detections            \(raw)")
        print("  after duration/token      \(afterDuration)")
        print("  after speech              \(afterSpeech)")
        print("  after string gate \(gate)   \(afterGate)")
        print(String(
            format: "\n  %d of %d clips would propose something (%.0f%%)",
            withProposals, clips.count,
            Double(withProposals) / Double(clips.count) * 100
        ))
        print(String(format: "  %.2f proposals per clip overall",
                     Double(afterGate) / Double(clips.count)))

        if let path = casesPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(slotCases) {
                try? data.write(to: URL(fileURLWithPath: path))
                let count = slotCases.reduce(0) { $0 + $1.slots.count }
                print("\n  wrote \(slotCases.count) sentences, \(count) slots to \(path)")
            }
        }

        print("\n── every proposal ─────────────────────────────────────")
        for (pair, count) in census.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            print("    \(count > 1 ? "\(count)x " : "")\(pair)")
        }
    }

    /// Plain Levenshtein over the longer length, spaces removed — the gate's
    /// own metric, so a floor here means what it means everywhere else.
    static func similarity(_ a: String, _ b: String) -> Float {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = Swift.min(cur[j - 1] + 1, prev[j] + 1,
                                   prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Float(prev[y.count]) / Float(Swift.max(x.count, y.count))
    }
}
