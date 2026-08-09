import Accelerate
import Foundation

/// **Prototype. `PARROTFLOW_REFERENCE_MATCH=1`, off by default.**
///
/// A rejection filter on the vocabulary pass. It adds nothing and promotes
/// nothing. For every proposal the pass already made it cuts the audio the
/// proposal sits on, measures how far that audio is from this speaker's own
/// recordings of the term, and drops the proposal when it is too far.
///
/// The question it exists to answer: over 141 labelled clips the pass wins 28
/// and loses 19, and every one of the 19 is an *overwrite* — a term written
/// over a word the speaker actually said. An overwrite is a claim about sound
/// that nothing in the pass ever checks against sound the speaker made. This
/// checks it.
///
/// ## Why a distance and not a score
///
/// Everything acoustic tried before this scores a *spelling* against audio.
/// Round 5 measured that and it is inverted — AUC 0.318 at separating "the
/// term was said" from "the term was not said". This asks the other question:
/// does the span sound like the recordings in `voice/samples/<Term>/`? No
/// spelling, no model, no decoder. MFCCs and DTW, ported from
/// `scripts/reference-matching.py` on `origin/spike/reference-matching`.
///
/// ## Why the threshold is per term
///
/// Round 7 found the distance scale differs per term: `Matthieu`'s entire true
/// range sat above `Praisy`'s entire false range. A single global number
/// cannot separate both. So the span is compared against the term's own
/// spread — the leave-one-out nearest-neighbour distances between that term's
/// recordings. See `Threshold`.
///
/// ## What it will not do
///
/// A term with too few recordings does not get to reject anything. Round 7
/// scored `Matthieu` at chance on two recordings. Below
/// `minimumRecordings` the filter abstains rather than guesses.
enum ReferenceMatch {

    // MARK: - The switch and the constants

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["PARROTFLOW_REFERENCE_MATCH"] == "1"
    }

    /// Where the per-proposal measurements go, when something asked for them.
    /// One TSV line per proposal, so a constant can be picked from real
    /// distances instead of guessed.
    static var dumpPath: String? {
        ProcessInfo.processInfo.environment["PARROTFLOW_REFERENCE_DUMP"]
    }

    /// **The one constant.** How much farther than the term's own spread a
    /// span may sit before the proposal is dropped.
    ///
    /// The rule, in words: a term's recordings sit some distance from each
    /// other. Take the largest of those distances — the width of the cloud.
    /// A span belonging to the term should land inside the cloud. Reject when
    /// it lands more than `tolerance` times the cloud's width away.
    ///
    /// 1.0 is the literal reading and it is the wrong default: the archive was
    /// mined automatically and a term's worst recording is sometimes not the
    /// term at all — `Vercel/09-brazil.wav`, `Tasmeen/06-that'smeanssend.wav`.
    /// One bad recording widens the cloud for every proposal. The measured
    /// value is in `docs/proposals/reference-matching-proto.md`.
    static var tolerance: Double {
        ProcessInfo.processInfo.environment["PARROTFLOW_REFERENCE_TOL"]
            .flatMap(Double.init) ?? 1.0
    }

    /// Below this many usable recordings the filter abstains.
    ///
    /// Three, from round 7: `Matthieu` on two recordings separated at chance.
    /// Two recordings give exactly one exemplar-to-exemplar distance, so the
    /// "spread" is a single number with no spread in it.
    static let minimumRecordings = 3

    /// Padding each side of a proposal's span, in seconds.
    ///
    /// The same 0.05 `scripts/mine-pronunciations.py` cuts with, so a span is
    /// cut the way the recordings it is compared against were. A word's edges
    /// are where it is least clear.
    static let pad = 0.05

    static let rate = 16000.0

    // MARK: - What comes back

    enum Verdict {
        /// Drop the proposal. Carries the numbers, for the log.
        case reject(distance: Double, spread: Double, recordings: Int)
        /// Leave the proposal alone.
        case keep(distance: Double, spread: Double, recordings: Int)
        /// Nothing was measured. The filter never removes on this.
        case abstain(why: String)

        var rejects: Bool { if case .reject = self { return true }; return false }
    }

    // MARK: - The recordings

    /// One recording of one term, with its MFCCs and where it came from.
    private struct Exemplar {
        let name: String
        /// The clip it was cut out of, from `voice/observations.jsonl`. Nil
        /// when nothing recorded it.
        let clip: String?
        let mfcc: [[Double]]
    }

    /// Everything known about one term, computed once.
    private struct Reference {
        let exemplars: [Exemplar]
        /// `pairwise[i][j]` — DTW between recording i and recording j.
        let pairwise: [[Double]]
    }

    /// How long the last `verdict` took, in milliseconds. Read by the dump.
    /// A global rather than a return value because it is a measurement of a
    /// prototype and not part of what the filter answers.
    nonisolated(unsafe) private static var lastMilliseconds = 0.0

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Reference?] = [:]
    nonisolated(unsafe) private static var provenance: [String: String]?

    /// A term and its possessive or plural are the same name, and the folder
    /// under `samples/` carries the bare term.
    static func stem(_ word: String) -> String {
        var bare = word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
        for suffix in ["'s", "s'", "s"] where bare.count > 3 && bare.hasSuffix(suffix) {
            bare = String(bare.dropLast(suffix.count))
            break
        }
        return bare
    }

    /// `sample path -> source clip`, read once from `voice/observations.jsonl`.
    ///
    /// Provenance matters because the recordings were mined from the very
    /// clips this is measured on. Without it a span is compared against a copy
    /// of itself, scores ~0, and is never rejected — which flatters the filter
    /// on exactly the clips it is being judged by. 49 of the 145 cases are
    /// sources of a recording.
    private static func sources() -> [String: String] {
        if let provenance { return provenance }
        var found: [String: String] = [:]
        if let text = try? String(contentsOf: VoiceStore.observationsURL, encoding: .utf8) {
            let decoder = JSONDecoder()
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let row = try? decoder.decode(VoiceStore.Observation.self, from: data),
                      let sample = row.sample, let wav = row.wav
                else { continue }
                found[(sample as NSString).lastPathComponent] = wav
            }
        }
        provenance = found
        return found
    }

    /// The recordings of one term, their MFCCs and every distance between
    /// them. Built once per process — the pairwise matrix is the expensive
    /// part and a clip hold-out only ever removes rows from it.
    private static func reference(for term: String) -> Reference? {
        let key = stem(term)
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }

        let started = Date()
        let files = FileManager.default
        let root = VoiceStore.samplesDirectory
        let folders = (try? files.contentsOfDirectory(atPath: root.path)) ?? []
        guard let folder = folders.first(where: { stem($0) == key }) else {
            cache[key] = Reference?.none
            return nil
        }
        let directory = root.appendingPathComponent(folder)
        let wavs = ((try? files.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".wav") }.sorted()
        let where_ = sources()

        var exemplars: [Exemplar] = []
        for name in wavs {
            guard let samples = readWav(directory.appendingPathComponent(name)),
                  let mfcc = mfcc(samples)
            else { continue }
            exemplars.append(Exemplar(name: name, clip: where_[name], mfcc: mfcc))
        }
        var pairwise = [[Double]](
            repeating: [Double](repeating: 0, count: exemplars.count),
            count: exemplars.count
        )
        for i in exemplars.indices {
            for j in (i + 1)..<exemplars.count {
                let distance = dtw(exemplars[i].mfcc, exemplars[j].mfcc)
                pairwise[i][j] = distance
                pairwise[j][i] = distance
            }
        }
        let built = Reference(exemplars: exemplars, pairwise: pairwise)
        cache[key] = built
        // Once per term per process: reading the wavs, their MFCCs and every
        // distance between them. Everything after this is one span against a
        // table already in memory, so the two costs are reported apart.
        Log.write(String(
            format: "reference: %@ — %d recording(s) read and cross-measured in %.0f ms",
            folder, exemplars.count, Date().timeIntervalSince(started) * 1000
        ))
        return built
    }

    // MARK: - The verdict

    /// Does this span sound like the recordings of this term?
    ///
    /// - Parameters:
    ///   - term: the term proposed, in any inflection.
    ///   - samples: the whole clip, 16 kHz mono.
    ///   - start, end: the proposal's span in seconds, unpadded.
    ///   - clip: the file being transcribed, so a recording mined out of this
    ///     same clip can be held out. Nil during live dictation, where the
    ///     audio has no name and nothing was mined from it yet.
    static func verdict(
        term: String, samples: [Float], start: Double, end: Double, clip: String?
    ) -> Verdict {
        let started = Date()
        defer { lastMilliseconds = Date().timeIntervalSince(started) * 1000 }
        guard let reference = reference(for: term) else {
            return .abstain(why: "no recordings of \(stem(term))")
        }
        // Held out: anything mined from the clip being transcribed. See
        // `sources()` for why this is not optional.
        let usable = reference.exemplars.indices.filter {
            clip == nil || reference.exemplars[$0].clip != clip
        }
        guard usable.count >= minimumRecordings else {
            return .abstain(why: "\(usable.count) recording(s), under \(minimumRecordings)")
        }

        let first = max(0, Int((start - pad) * rate))
        let last = min(samples.count, Int((end + pad) * rate))
        guard last > first else { return .abstain(why: "empty span") }
        let cut = samples[first..<last].map { Double($0) }
        guard let span = mfcc(cut) else { return .abstain(why: "span under one frame") }

        var distance = Double.infinity
        for index in usable {
            distance = min(distance, dtw(span, reference.exemplars[index].mfcc))
        }

        // The term's own spread: for each recording, how far the nearest other
        // recording of the same term is. The largest of those is the width of
        // the cloud the span has to land inside.
        var nearest: [Double] = []
        for index in usable {
            var best = Double.infinity
            for other in usable where other != index {
                best = min(best, reference.pairwise[index][other])
            }
            if best.isFinite { nearest.append(best) }
        }
        guard let spread = nearest.max(), spread > 0 else {
            return .abstain(why: "no spread to compare against")
        }

        if distance > tolerance * spread {
            return .reject(distance: distance, spread: spread, recordings: usable.count)
        }
        return .keep(distance: distance, spread: spread, recordings: usable.count)
    }

    /// One line per proposal, for picking the constant off real numbers.
    static func dump(
        clip: String?, term: String, heard: String, start: Double, end: Double,
        verdict: Verdict
    ) {
        guard let path = dumpPath else { return }
        var line = "\(clip ?? "-")\t\(term)\t\(heard)"
        line += String(format: "\t%.2f\t%.2f", start, end)
        switch verdict {
        case .reject(let distance, let spread, let recordings),
             .keep(let distance, let spread, let recordings):
            line += String(format: "\t%.4f\t%.4f\t%d\t%@", distance, spread, recordings,
                           verdict.rejects ? "reject" : "keep")
        case .abstain(let why):
            line += "\t\t\t0\tabstain: \(why)"
        }
        line += String(format: "\t%.2f", lastMilliseconds)
        append(line + "\n", to: path)
    }

    private static func append(_ text: String, to path: String) {
        lock.lock()
        defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Reading a recording

    /// int16 mono samples from a wav, as doubles. Nil on anything else.
    ///
    /// Hand-rolled rather than AVFoundation: every file under
    /// `voice/samples/` was written by this app at 16 kHz mono int16, and a
    /// decode through AVFoundation costs a format conversion for each of 122
    /// files at load.
    private static func readWav(_ url: URL) -> [Double]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        func word(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func long(_ at: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        guard bytes.count > 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE"
        else { return nil }

        var cursor = 12
        var channels = 1, bits = 16
        while cursor + 8 <= bytes.count {
            let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let size = long(cursor + 4)
            let body = cursor + 8
            if id == "fmt " , body + 16 <= bytes.count {
                channels = word(body + 2)
                bits = word(body + 14)
            } else if id == "data" {
                guard bits == 16, channels >= 1 else { return nil }
                let end = min(bytes.count, body + size)
                var out: [Double] = []
                out.reserveCapacity((end - body) / (2 * channels))
                var at = body
                while at + 2 * channels <= end {
                    var sum = 0.0
                    for channel in 0..<channels {
                        let raw = word(at + 2 * channel)
                        sum += Double(raw > 32767 ? raw - 65536 : raw)
                    }
                    out.append(sum / Double(channels))
                    at += 2 * channels
                }
                return out
            }
            cursor = body + size + (size % 2)
        }
        return nil
    }

    // MARK: - The MFCC

    private static let filters = 26
    private static let nfft = 512
    private static let keep = 12

    /// 26 triangular mel filters over the 257 rfft bins, built once.
    private static let bank: [[Double]] = {
        func mel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
        func hz(_ m: Double) -> Double { 700.0 * (pow(10.0, m / 2595.0) - 1.0) }
        let low = mel(0), high = mel(rate / 2)
        let points = (0...(filters + 1)).map { index -> Int in
            let m = low + (high - low) * Double(index) / Double(filters + 1)
            return Int(floor(Double(nfft + 1) * hz(m) / rate))
        }
        var built = [[Double]](
            repeating: [Double](repeating: 0, count: nfft / 2 + 1), count: filters
        )
        for i in 0..<filters {
            let left = points[i], middle = points[i + 1], right = points[i + 2]
            if middle > left {
                for k in left..<middle where k >= 0 && k < nfft / 2 + 1 {
                    built[i][k] = Double(k - left) / Double(middle - left)
                }
            }
            if right > middle {
                for k in middle..<right where k >= 0 && k < nfft / 2 + 1 {
                    built[i][k] = Double(right - k) / Double(right - middle)
                }
            }
        }
        return built
    }()

    /// The DCT-II rows that turn 26 log energies into 13 cepstra.
    private static let dct: [[Double]] = (0..<13).map { i in
        (0..<filters).map { j in
            cos(Double.pi / Double(filters) * (Double(j) + 0.5) * Double(i))
        }
    }

    private static let hamming: [Double] = {
        let length = Int(0.025 * rate)
        return (0..<length).map {
            0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(length - 1))
        }
    }()

    nonisolated(unsafe) private static let fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))

    /// 12 cepstra, c0 dropped, mean and variance normalised over the segment.
    ///
    /// c0 is loudness. Two recordings of the same word at different distances
    /// from the microphone differ in it and in nothing that matters here. The
    /// normalisation does the same job for the rest: it takes out the channel
    /// and leaves the shape of the spectrum over time.
    static func mfcc(_ samples: [Double]) -> [[Double]]? {
        let length = Int(0.025 * rate), step = Int(0.010 * rate)
        guard samples.count >= length, let fft else { return nil }

        // Pre-emphasis, 0.97.
        var emphasised = [Double](repeating: 0, count: samples.count)
        emphasised[0] = samples[0]
        for i in 1..<samples.count { emphasised[i] = samples[i] - 0.97 * samples[i - 1] }

        let count = 1 + (samples.count - length) / step
        var cepstra = [[Double]](repeating: [Double](repeating: 0, count: keep), count: count)

        var real = [Float](repeating: 0, count: nfft / 2)
        var imag = [Float](repeating: 0, count: nfft / 2)
        var padded = [Float](repeating: 0, count: nfft)

        for frame in 0..<count {
            let base = frame * step
            for i in 0..<length { padded[i] = Float(emphasised[base + i] * hamming[i]) }
            for i in length..<nfft { padded[i] = 0 }

            var power = [Double](repeating: 0, count: nfft / 2 + 1)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: nfft / 2
                        ) { pairs in
                            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(nfft / 2))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, 9, FFTDirection(FFT_FORWARD))
                    // vDSP packs the real transform: realp[0] is the DC term
                    // and imagp[0] is Nyquist, both real. Everything comes
                    // back scaled by 2, so each is halved to match a plain
                    // rfft — the numbers have to line up with the Python this
                    // was ported from.
                    let dc = Double(rp[0]) / 2
                    let nyquist = Double(ip[0]) / 2
                    power[0] = dc * dc / Double(nfft)
                    power[nfft / 2] = nyquist * nyquist / Double(nfft)
                    for k in 1..<(nfft / 2) {
                        let re = Double(rp[k]) / 2, im = Double(ip[k]) / 2
                        power[k] = (re * re + im * im) / Double(nfft)
                    }
                }
            }

            var energy = [Double](repeating: 0, count: filters)
            for i in 0..<filters {
                var sum = 0.0
                let row = bank[i]
                for k in 0..<power.count where row[k] != 0 { sum += power[k] * row[k] }
                energy[i] = log(max(sum, 1e-10))
            }
            for i in 1...keep {
                var sum = 0.0
                let row = dct[i]
                for j in 0..<filters { sum += energy[j] * row[j] }
                cepstra[frame][i - 1] = sum
            }
        }

        // Mean and variance normalised per coefficient, over the segment.
        for coefficient in 0..<keep {
            var mean = 0.0
            for frame in 0..<count { mean += cepstra[frame][coefficient] }
            mean /= Double(count)
            var variance = 0.0
            for frame in 0..<count {
                let centred = cepstra[frame][coefficient] - mean
                variance += centred * centred
            }
            let deviation = (variance / Double(count)).squareRoot()
            let scale = deviation < 1e-6 ? 1.0 : deviation
            for frame in 0..<count {
                cepstra[frame][coefficient] = (cepstra[frame][coefficient] - mean) / scale
            }
        }
        return cepstra
    }

    // MARK: - The DTW

    /// Normalised DTW distance between two MFCC sequences.
    ///
    /// Symmetric step pattern, diagonal weighted 2, so the accumulated cost
    /// divides exactly by n + m and sequences of different length compare.
    static func dtw(_ a: [[Double]], _ b: [[Double]]) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        var previous = [Double](repeating: .infinity, count: m + 1)
        var row = [Double](repeating: .infinity, count: m + 1)
        previous[0] = 0

        for i in 1...n {
            let left = a[i - 1]
            row[0] = .infinity
            for j in 1...m {
                let right = b[j - 1]
                var sum = 0.0
                for k in 0..<left.count {
                    let d = left[k] - right[k]
                    sum += d * d
                }
                let here = sum.squareRoot()
                row[j] = Swift.min(
                    previous[j] + here,
                    Swift.min(row[j - 1] + here, previous[j - 1] + 2 * here)
                )
            }
            swap(&previous, &row)
        }
        return previous[m] / Double(n + m)
    }

    // MARK: - Proving the port

    /// `--reference-selftest <Term>` — every distance between that term's
    /// recordings, on stdout.
    ///
    /// The algorithm is a port of `scripts/reference-matching.py`, and a port
    /// that is subtly wrong reads exactly like a port that is right. This
    /// prints the numbers so the Python can print the same ones and the two
    /// can be diffed. It is the only test this prototype has.
    static func selfTest(term: String) -> Int32 {
        guard let reference = reference(for: term) else {
            print("✗ no recordings of \(stem(term)) under \(VoiceStore.samplesDirectory.path)")
            return 1
        }
        for i in reference.exemplars.indices {
            for j in (i + 1)..<reference.exemplars.count {
                print(String(format: "%@\t%@\t%.6f", reference.exemplars[i].name,
                             reference.exemplars[j].name, reference.pairwise[i][j]))
            }
        }
        return 0
    }
}
