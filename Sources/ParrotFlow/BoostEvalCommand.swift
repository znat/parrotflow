import AVFoundation
import FluidAudio
import Foundation

/// `--boost-eval [--terms "a,b"] [--limit N] [--verbose]` — measures whether
/// vocabulary boosting can be made safe enough to turn on.
///
/// Boosting was measured in July and removed: 48 of 50 clips containing none
/// of the vocabulary came out different with it on. That run swept
/// `minSimilarity` to 0.90 and the damage did not move, which read as "not a
/// threshold to tune".
///
/// It was the wrong threshold. FluidAudio proposes a replacement two ways:
///
/// 1. **TDT-anchored** — Levenshtein match against the decoded words. This is
///    what `minSimilarity` gates.
/// 2. **Spotter-anchored rescue** — the CTC keyword spotter says it heard the
///    term over a span, and the span is replaced. From
///    `VocabularyRescorer+TokenRescoring.swift:932`: it "is acoustic-evidence
///    driven and otherwise ignores similarity".
///
/// The July run passed no `VocabularyRescorer.Config`, so it got `.default`:
/// rescue on, both of its similarity floors at 0.0 — disabled. The sweep moved
/// gate 1 while gate 2 stayed open. FluidAudio's own #702/#724 notes name the
/// rescue as the dominant source of short-keyword over-firing, and it only
/// runs at all when the vocabulary has 10 terms or fewer — which is every
/// vocabulary anyone would write here.
///
/// So this sweeps the knobs that gate the rescue. The number that decides it
/// is still **damage**: clips containing none of the vocabulary that come out
/// different with boosting on. Recall is secondary — `replacements` already
/// delivers the names at zero damage, so boosting only earns its place by
/// being safe.
///
/// One pass over the clips serves every variant. Transcription and the CTC
/// forward pass are the expensive parts and they do not depend on the config,
/// so each clip is decoded once and then rescored once per variant.
@available(macOS 14, *)
enum BoostEvalCommand {

    struct Case {
        let url: URL
        let baseline: String
        let hasTerm: Bool
    }

    /// One rescorer configuration, and the two arguments that are passed per
    /// call rather than held in `Config`.
    struct Variant {
        let name: String
        let config: VocabularyRescorer.Config
        /// nil means "whatever `rescorerConfig(forVocabSize:)` says".
        let minSimilarity: Float?
    }

    /// What one variant did over the whole set.
    struct Tally {
        var recovered = 0
        var unchangedPositives = 0
        var damagedPositives = 0
        /// Positives where the decoder wrote the name correctly on its own.
        /// Nothing for a vocabulary to do, so they are not scored against it.
        var decoderAlreadyRight = 0
        /// Positives where the decoder got the name wrong and the vocabulary
        /// put it right. This is the number that says whether one list entry
        /// covers renderings no rule was written for.
        var caughtUnaided = 0
        /// Positives where the decoder got the name wrong and the vocabulary
        /// did not catch it either.
        var missed = 0
        /// `(what was said, what the decoder wrote)` for the misses — the
        /// renderings a vocabulary would still need a rule for.
        var missedExamples: [(String, String)] = []
        var damagedNegatives = 0
        /// Every substitution the variant made, as `heard -> written`, counted.
        ///
        /// The tallies above lean on a stored baseline to decide whether a clip
        /// contained a term, and that baseline is stale: a clip whose trace
        /// says "Olama" is labelled a negative, so boosting writing "Ollama"
        /// over it is scored as damage when it is the fix you wanted. The
        /// census does not label anything. It shows what each change replaced,
        /// which is the only thing that settles those cases.
        var substitutions: [String: Int] = [:]
        /// `(sentence, heard, written)` for every substitution, kept whole so
        /// a judge can be scored on the same sentences the rescorer saw. The
        /// census counts pairs; a judge needs the words either side of them.
        var proposals: [(String, String, String)] = []
    }

    // FluidAudio's recommended short-vocab opt-in values, from the #702 note
    // in ContextBiasingConstants: taper pivot 5 / exponent 2.0, spotter floors
    // 0.30 single-word and 0.50 multi-word.
    private static let taperPivot = 5
    private static let taperExponent: Float = 2.0
    private static let spotterFloor: Float = 0.30
    private static let spotterFloorMulti: Float = 0.50

    /// The sweep. `default` is first so every run reproduces the July number
    /// on the same clips as the rest — a variant is only interesting relative
    /// to the baseline measured in the same pass.
    private static func variants() -> [Variant] {
        func config(
            rescue: Bool, taper: Bool, floors: Bool
        ) -> VocabularyRescorer.Config {
            VocabularyRescorer.Config(
                shortTermCbwTaperPivot: taper ? taperPivot : 1,
                shortTermCbwTaperExponent: taperExponent,
                spotterRescueMinSimilarity: floors ? spotterFloor : 0.0,
                spotterRescueMultiWordMinSimilarity: floors ? spotterFloorMulti : 0.0,
                spotterRescueEnabled: rescue
            )
        }
        return [
            Variant(name: "default (July)", config: config(rescue: true, taper: false, floors: false),
                    minSimilarity: nil),
            Variant(name: "floors", config: config(rescue: true, taper: false, floors: true),
                    minSimilarity: nil),
            Variant(name: "floors+taper", config: config(rescue: true, taper: true, floors: true),
                    minSimilarity: nil),
            Variant(name: "rescue-off", config: config(rescue: false, taper: false, floors: false),
                    minSimilarity: nil),
            Variant(name: "rescue-off+taper", config: config(rescue: false, taper: true, floors: false),
                    minSimilarity: nil),
            Variant(name: "rescue-off+taper sim.65", config: config(rescue: false, taper: true, floors: false),
                    minSimilarity: 0.65),
            Variant(name: "rescue-off+taper sim.75", config: config(rescue: false, taper: true, floors: false),
                    minSimilarity: 0.75),
            Variant(name: "rescue-off+taper sim.85", config: config(rescue: false, taper: true, floors: false),
                    minSimilarity: 0.85),
        ]
    }

    /// Writes every proposal one variant made as a case file, for tuning a
    /// judge that approves or declines them.
    ///
    /// Harvested from the loosest variant on purpose. A judge is only worth
    /// having if it can tell `Olama -> Ollama` from `verify -> Vercel`, and the
    /// strict settings never propose the second — so a set built from them
    /// would have no negatives in it and would score any judge at 100%.
    ///
    /// `expect` is left blank. Whether a substitution was right is a judgement
    /// about what the speaker meant, and a set labelled by the same rule the
    /// judge is being scored against measures nothing.
    private static func writeCases(_ tally: Tally, to path: String, variant: String) {
        var lines = [
            "# Judge cases: name substitutions proposed by the vocabulary pass.",
            "#",
            "# Harvested from --boost-eval, variant \"\(variant)\", over the",
            "# recordings on disk. `said` is raw decoder output with no",
            "# replacement pass, which is what the judge sees at run time.",
            "#",
            "# expect: approve — the name was misheard and this puts it right",
            "# expect: decline — an ordinary word is about to be overwritten",
            "#",
            "# Fill in `expect` by hand. Half of these should be declines: the",
            "# stage runs on every transcript, so a confident wrong approval",
            "# costs more than a missed name.",
            "",
            "cases:",
        ]
        var seen = Set<String>()
        for (said, heard, written) in tally.proposals {
            guard seen.insert("\(heard)|\(written)").inserted else { continue }
            func quoted(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            lines.append("  - said: \(quoted(said))")
            lines.append("    heard: \(quoted(heard))")
            lines.append("    term: \(quoted(written))")
            lines.append("    expect:")
            lines.append("")
        }
        do {
            try lines.joined(separator: "\n").write(
                toFile: path, atomically: true, encoding: .utf8
            )
            print("\n  wrote \(seen.count) cases to \(path) — fill in `expect` by hand")
        } catch {
            print("\n  ✗ could not write \(path): \(error.localizedDescription)")
        }
    }

    static func run(
        terms explicit: [String]?, limit: Int, verbose: Bool, casesPath: String? = nil
    ) -> Int32 {
        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        let terms = explicit ?? vocabularyFromConfig(config)
        guard !terms.isEmpty else {
            print("✗ no vocabulary: pass --terms \"Supabase,Tasmeen\" or add"
                + " replacement targets of 5+ characters to the config")
            return 1
        }

        let recordings = config.resolvedOutputDir
        // A fixed sample, not a shuffled one. Two runs of a measurement harness
        // have to be comparable, and `shuffled()` made the clip set differ
        // between them — one run scored 240 negatives and the next 239, for no
        // reason anyone could see. Striding the sorted list keeps the sample
        // spread over the whole archive rather than taking the oldest N.
        let all = clipsWithBaselines(terms: terms, in: recordings)
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        let stride = max(1, all.count / max(1, limit))
        let clips = Array(all.enumerated().filter { $0.offset.isMultiple(of: stride) }
            .map(\.element).prefix(limit))
        guard !clips.isEmpty else {
            print("✗ no clips with a known transcript in \(Log.fileURL.lastPathComponent)"
                + " that still exist in \(recordings.path)")
            return 1
        }
        let positives = clips.filter(\.hasTerm).count

        print("vocabulary:   \(terms.joined(separator: ", "))  (\(terms.count) terms)")
        if terms.count > ContextBiasingConstants.largeVocabThreshold {
            print("              over \(ContextBiasingConstants.largeVocabThreshold) terms — the"
                + " spotter rescue is size-gated off, so the rescue variants are no-ops")
        }
        print("clips:        \(clips.count)  (\(positives) contain a term, \(clips.count - positives) do not)")
        print("")

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            do { try await evaluate(clips: clips, terms: terms, verbose: verbose, casesPath: casesPath) }
            catch { print("✗ \(error.localizedDescription)"); code = 1 }
            done.signal()
        }
        done.wait()
        return code
    }

    private static func evaluate(
        clips: [Case], terms: [String], verbose: Bool, casesPath: String? = nil
    ) async throws {
        print("loading models…")
        let models = try await AsrModels.downloadAndLoad()
        let asr = AsrManager(models: models)
        let ctcModels = try await CtcModels.downloadAndLoad()
        let ctcDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: ctcDirectory)

        // Pre-tokenising is the step that makes the spotter fire at all: a term
        // built as `CustomVocabularyTerm(text:)` alone carries no ctcTokenIds
        // and is silently skipped. This is what commit b137505 found.
        let vocabulary = CustomVocabularyContext(
            terms: terms.compactMap { term in
                let ids = tokenizer.encode(term)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
            }
        )
        guard !vocabulary.terms.isEmpty else {
            print("✗ every term tokenised to nothing")
            return
        }

        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
        let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)

        let sweep = variants()
        var rescorers: [VocabularyRescorer] = []
        for variant in sweep {
            rescorers.append(try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: vocabulary,
                config: variant.config, ctcModelDirectory: ctcDirectory
            ))
        }
        print("ready.  cbw \(sizeConfig.cbw), size-default minSimilarity \(sizeConfig.minSimilarity)\n")

        var tallies = [Tally](repeating: Tally(), count: sweep.count)
        // Both counted over the clips that were actually scored. A clip that
        // failed to load, decoded to nothing, or returned no CTC frames is
        // skipped, and counting its positives anyway made `negatives` too
        // small — negative, on a bad enough run — and overstated how many
        // names the vocabulary had failed to fix.
        var decoded = 0
        var decodedPositives = 0

        for (index, clip) in clips.enumerated() {
            guard let samples = load(url: clip.url) else { continue }

            // The batch path, which is what the app runs. The streaming manager
            // builds its token timings from an encoder sequence length of zero,
            // and the rescorer needs real ones to know which word a detection
            // sits on.
            var decoderState = await TdtDecoderState.make(decoderLayers: asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            let off = result.text
            guard let timings = result.tokenTimings, !timings.isEmpty else { continue }

            // One CTC forward pass, reused by every variant.
            let spotted = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocabulary, minScore: nil
            )
            guard !spotted.logProbs.isEmpty else { continue }
            decoded += 1
            if clip.hasTerm { decodedPositives += 1 }

            for (slot, variant) in sweep.enumerated() {
                let on = rescorers[slot].ctcTokenRescore(
                    transcript: off,
                    tokenTimings: timings,
                    logProbs: spotted.logProbs,
                    frameDuration: spotted.frameDuration,
                    cbw: sizeConfig.cbw,
                    marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                    minSimilarity: variant.minSimilarity ?? sizeConfig.minSimilarity
                ).text
                record(
                    clip: clip, off: off, on: on, terms: terms,
                    into: &tallies[slot]
                )
            }

            if (index + 1) % 10 == 0 { print("  \(index + 1)/\(clips.count)…") }
        }

        report(
            sweep: sweep, tallies: tallies, positives: decodedPositives,
            decoded: decoded, verbose: verbose
        )

        // The loosest variant that still has the rescue off — the one that
        // proposes both the catches and the junk, so a judge set has negatives.
        if let path = casesPath,
           let slot = sweep.firstIndex(where: { $0.name == "rescue-off+taper" }) {
            writeCases(tallies[slot], to: path, variant: sweep[slot].name)
        }
    }

    /// Scores one clip under one variant.
    ///
    /// A positive that changed only counts as recovered when the change put a
    /// vocabulary term in that was not there before. A positive that changed
    /// some other way is damage too — boosting rewriting the rest of a
    /// sentence to land a name is not a win.
    private static func record(
        clip: Case, off: String, on: String, terms: [String],
        into tally: inout Tally
    ) {
        // The question a vocabulary exists to answer: the name was spoken, the
        // decoder got it wrong, and no rule was written for this rendering —
        // does one list entry catch it anyway? The off-arm here is raw ASR with
        // no replacement pass, so a positive the decoder already got right is
        // not a case boosting has to solve, and is set aside.
        if clip.hasTerm {
            let decoderHadIt = terms.contains { off.localizedCaseInsensitiveContains($0) }
            if decoderHadIt {
                tally.decoderAlreadyRight += 1
            } else if terms.contains(where: { on.localizedCaseInsensitiveContains($0) }) {
                tally.caughtUnaided += 1
            } else {
                tally.missed += 1
                if tally.missedExamples.count < 12 {
                    tally.missedExamples.append((clip.baseline, off))
                }
            }
        }

        guard normalise(off) != normalise(on) else {
            if clip.hasTerm { tally.unchangedPositives += 1 }
            return
        }
        for (heard, written) in substitutions(from: off, to: on) {
            tally.substitutions["\(heard) -> \(written)", default: 0] += 1
            tally.proposals.append((off, heard, written))
        }
        let gained = terms.contains {
            on.localizedCaseInsensitiveContains($0) && !off.localizedCaseInsensitiveContains($0)
        }
        if clip.hasTerm, gained {
            tally.recovered += 1
        } else if clip.hasTerm {
            tally.damagedPositives += 1
        } else {
            tally.damagedNegatives += 1
        }
    }

    private static func report(
        sweep: [Variant], tallies: [Tally], positives: Int, decoded: Int, verbose: Bool
    ) {
        let negatives = decoded - positives

        func row(_ cells: [String]) -> String {
            "  " + cells.enumerated().map { index, cell in
                index == cells.count - 1
                    ? cell : cell.padding(toLength: index == 0 ? 24 : 11, withPad: " ", startingAt: 0)
            }.joined()
        }

        // The decoder gets some names right unaided, and those are not cases a
        // vocabulary has to solve. Every variant sees the same off-arm, so this
        // count is the same for all of them.
        let alreadyRight = tallies.first?.decoderAlreadyRight ?? 0
        let toFix = positives - alreadyRight

        print("\n── \(decoded) clips scored ────────────────────────────────────")
        print("  \(positives) clips said a vocabulary name."
            + " The decoder wrote \(alreadyRight) of them correctly on its own,")
        print("  so \(toFix) are what a vocabulary has to earn — with no"
            + " replacement rule of any kind.\n")
        print(row(["variant", "damage", "caught", "missed", "pos.hurt"]))
        for (slot, variant) in sweep.enumerated() {
            let tally = tallies[slot]
            let damage = negatives > 0 ? "\(tally.damagedNegatives)/\(negatives)" : "—"
            print(row([
                variant.name, damage,
                "\(tally.caughtUnaided)/\(toFix)", "\(tally.missed)",
                "\(tally.damagedPositives)",
            ]))
        }
        print("\n  damage    negatives altered — must be 0")
        print("  caught    name misheard, no rule for it, vocabulary put it right")
        print("  missed    name misheard and the vocabulary did not catch it either")
        print("  pos.hurt  positives changed some other way")

        // What the decoder wrote for the ones nothing caught. These are the
        // renderings that would still need a rule, and they are the honest
        // limit on replacing the table with a list.
        if let strictest = sweep.indices.last, !tallies[strictest].missedExamples.isEmpty {
            print("\n  still missed by \(sweep[strictest].name):")
            for (said, heard) in tallies[strictest].missedExamples.prefix(12) {
                print("    said:  \(said.prefix(88))")
                print("    heard: \(heard.prefix(88))")
            }
        }

        // The census, for the variants worth deciding between. Every change
        // they made, as heard -> written, so a "damage" that is really a fix
        // is visible as one.
        for slot in sweep.indices where !tallies[slot].substitutions.isEmpty {
            guard verbose || tallies[slot].damagedNegatives <= max(3, negatives / 40)
            else { continue }
            print("\n  \(sweep[slot].name) — every substitution it made:")
            let ordered = tallies[slot].substitutions.sorted {
                ($0.value, $1.key) > ($1.value, $0.key)
            }
            for (pair, count) in ordered.prefix(30) {
                print("    \(count > 1 ? "\(count)x " : "")\(pair)")
            }
            if ordered.count > 30 { print("    …and \(ordered.count - 30) more") }
        }

        let best = sweep.indices.min {
            (tallies[$0].damagedNegatives, -tallies[$0].recovered)
                < (tallies[$1].damagedNegatives, -tallies[$1].recovered)
        }
        if let best {
            let tally = tallies[best]
            let safe = tally.damagedNegatives == 0 && tally.damagedPositives == 0
            print("\n  best: \(sweep[best].name)"
                + " — \(tally.damagedNegatives) damaged, \(tally.recovered) recovered")
            print("  verdict: \(safe && tally.recovered > 0 ? "SAFE — worth wiring in" : "NOT SAFE — boosting stays off")")
        }
    }

    /// Replacement targets are the vocabulary: those are exactly the words
    /// worth boosting and they are already in the config. Short terms are
    /// dropped — they do the over-firing, and a three-character term is the
    /// worst case for a free-start CTC alignment. The disfluency table's `""`
    /// target and any regex source are not words and are skipped.
    private static func vocabularyFromConfig(_ config: Config) -> [String] {
        config.transcription.replacements.keys
            .filter { $0.count >= 5 && $0.allSatisfy(\.isLetter) }
            .sorted()
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

    /// The word spans that differ between the two transcripts, as
    /// `(heard, written)` pairs.
    ///
    /// A word-level LCS: the words both sides agree on are the anchors, and
    /// each run between two anchors is one substitution. Comparison ignores
    /// case and trailing punctuation, so "merge," and "merge" are the same
    /// anchor and a lost comma is not reported as a change.
    static func substitutions(from off: String, to on: String) -> [(String, String)] {
        let before = off.split(separator: " ").map(String.init)
        let after = on.split(separator: " ").map(String.init)
        func key(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        // lengths[i][j] = LCS of before[i...] and after[j...].
        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: after.count + 1), count: before.count + 1
        )
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[i][j] = key(before[i]) == key(after[j])
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var pairs: [(String, String)] = []
        var i = 0, j = 0
        var heard: [String] = [], written: [String] = []
        func flush() {
            if !heard.isEmpty || !written.isEmpty {
                pairs.append((
                    heard.isEmpty ? "∅" : heard.joined(separator: " "),
                    written.isEmpty ? "∅" : written.joined(separator: " ")
                ))
                heard = []; written = []
            }
        }
        while i < before.count, j < after.count {
            if key(before[i]) == key(after[j]) {
                flush()
                i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                heard.append(before[i]); i += 1
            } else {
                written.append(after[j]); j += 1
            }
        }
        while i < before.count { heard.append(before[i]); i += 1 }
        while j < after.count { written.append(after[j]); j += 1 }
        flush()
        return pairs
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clips paired with the transcript recorded for them, which was produced
    /// with boosting off and is therefore the baseline. Only used to decide
    /// whether the clip contains a vocabulary term; the off-arm text is decoded
    /// fresh so both arms come from the same build.
    ///
    /// `trace.jsonl` first, because it names the clip in the same record as the
    /// text — the log only puts them near each other, and it is trimmed. On this
    /// machine that is 427 clips against 186. The log is still read for the ones
    /// the trace predates, and a clip found in both is taken once.
    private static func clipsWithBaselines(terms: [String], in directory: URL) -> [Case] {
        var baselines: [String: String] = [:]

        if let trace = try? String(
            contentsOf: directory.appendingPathComponent("trace.jsonl"), encoding: .utf8
        ) {
            for line in trace.components(separatedBy: .newlines) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let wav = object["wav"] as? String,
                      let text = object["final"] as? String, !text.isEmpty
                else { continue }
                baselines[(wav as NSString).lastPathComponent] = text
            }
        }

        if let log = try? String(contentsOf: Log.fileURL, encoding: .utf8) {
            var pending: String?
            for line in log.components(separatedBy: .newlines) {
                if let match = line.range(
                    of: #"parrotflow-[\w\-T]+\.wav"#, options: .regularExpression
                ) {
                    pending = String(line[match])
                } else if let range = line.range(of: "transcribed: "), let file = pending {
                    if baselines[file] == nil {
                        baselines[file] = String(line[range.upperBound...])
                    }
                    pending = nil
                }
            }
        }

        return baselines.compactMap { file, text in
            let url = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Case(
                url: url,
                baseline: text,
                hasTerm: terms.contains { text.localizedCaseInsensitiveContains($0) }
            )
        }
    }
}
