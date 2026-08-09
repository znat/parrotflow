import Foundation

/// `voice/` — what this machine has heard this person say, kept beside the
/// config rather than in a git repository.
///
/// The vocabulary says which words matter. This says how they actually come
/// out of this mouth, on this microphone, over time. The two are different
/// kinds of thing and they had been sharing one file: `vocabulary.yaml` is a
/// setting a person reads, and a growing archive of renderings with counts and
/// clips is not.
///
///     voice/observations.jsonl        one line per rendering seen
///     voice/calibration.yaml          the bands the calibrate skill measured
///     voice/samples/<Term>/*.wav      the audio of each rendering, cut out
///
/// **Nothing here belongs in the repository.** The archive it was mined from is
/// somebody's voice saying their colleagues' names. `scripts/check-no-voice.sh`
/// refuses a commit that carries any of it, and `.gitignore` keeps it out of
/// `git add .`.
///
/// **The microphone is part of the observation.** A rendering is a fact about a
/// mouth *and* a capture chain, and this archive already straddles two mics.
/// Pooling them makes a band that describes neither. `mic` is optional because
/// it genuinely is not known for the clips mined before anything recorded it —
/// absent means unknown, never "the current one".
///
/// **Every observation says which build wrote it and which language was being
/// dictated.** Both are free at write time and neither can be recovered
/// afterwards. `lang` is the multilingual case: this speaker dictates in two
/// languages and one name has two pronunciations, so the tag says whether each
/// way a name is said has clips behind it. It decides nothing on its own — a
/// French name can be said the French way inside an English sentence. `build`
/// is the audit trail: a clip cut by a build whose span logic later changes is
/// a clip you cannot trust, and the stamp is the only way to tell which is
/// which.
enum VoiceStore {

    /// How many samples one term keeps.
    ///
    /// Not a storage limit — 25 wav files of half a second is nothing. It is a
    /// limit on how much one week of dictation can dominate a term's cloud.
    /// Recordings from the same session score about 0.06 AUC higher against
    /// each other than against another day's, so a term whose bank is 200 clips
    /// from one afternoon describes that afternoon. The archive's own terms sit
    /// at 8 to 26 clips, which is where this number comes from.
    static let perTermSampleCap = 25

    static var directory: URL {
        ConfigStore.directory.appendingPathComponent("voice", isDirectory: true)
    }

    /// Append-only. Every line is one rendering seen once, so the same term and
    /// spelling appear as many times as they happened — the count is derived,
    /// never edited in place. A file that is only ever appended to can be read
    /// by anything and cannot lose a row to a concurrent write.
    static var observationsURL: URL {
        directory.appendingPathComponent("observations.jsonl")
    }

    /// What the calibrate skill measured: the band per term, in this person's
    /// voice. YAML rather than JSON because a person reads it and argues with
    /// it — see `.claude/skills/calibrate/SKILL.md`.
    static var calibrationURL: URL {
        directory.appendingPathComponent("calibration.yaml")
    }

    static var samplesDirectory: URL {
        directory.appendingPathComponent("samples", isDirectory: true)
    }

    /// What `calibration.yaml` says, in one line, for `--check-config`.
    ///
    /// Read rather than parsed. The file is written by
    /// `scripts/calibrate.py score` and read by a person; the app's interest in
    /// it is that it exists, when it was measured, and how many terms came out
    /// with no band — the ones that will never be safe acoustically for this
    /// speaker whatever the two file-level numbers say. Anything more would be
    /// a YAML schema, and this is a record rather than a setting.
    static func calibration() -> (measured: String, terms: Int, closed: Int)? {
        guard let text = try? String(contentsOf: calibrationURL, encoding: .utf8) else {
            return nil
        }
        var measured = "date not recorded"
        var terms = 0
        var closed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.hasPrefix("#") { continue }
            if bare.hasPrefix("measured:") {
                measured = String(bare.dropFirst("measured:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            // A term is a key indented two spaces under `terms:`; a band is
            // indented four under a term. Counting keys rather than decoding
            // keeps this working when the file grows a field.
            if line.hasPrefix("    band:") {
                terms += 1
                if bare.hasSuffix("closed") { closed += 1 }
            }
        }
        return (measured, terms, closed)
    }

    /// One rendering, seen once.
    struct Observation: Codable, Sendable, Equatable {
        /// ISO 8601, so a line sorts as text.
        var at: String
        var term: String
        var heard: String
        /// `correction`, `mined` or `calibration` — the same words
        /// `Config.Vocabulary.Pronunciation.Source` uses, kept as a string
        /// because a line written by a future version must still parse here.
        var from: String
        /// The acoustic score, when something measured one.
        var score: Float?
        /// The input device, when it was recorded. See the note above.
        var mic: String?
        /// `[start, end]` in seconds within the clip.
        var span: [Double]?
        /// The cut audio, relative to `voice/`. Relative so moving the config
        /// directory — which `PARROTFLOW_CONFIG_DIR` does on every harness run
        /// — does not invalidate every row.
        var sample: String?
        /// The clip it came out of, as a bare filename.
        var wav: String?
        /// Which language the pipeline was chosen for, from the dictation's own
        /// `trace.jsonl` line. Absent means the trace did not say — never "the
        /// current one", for the same reason `mic` is optional.
        var lang: String?
        /// The build stamp of whatever wrote this row, e.g. `78d7ba2`.
        /// `AppVariant.buildStamp`, the same string `--version` prints and the
        /// app's first log line carries.
        var build: String?
        /// Why this row has no `sample`, when it has none.
        ///
        /// A row that records a rendering but no audio is normal — the clip may
        /// be gone, the timings may not cover it, the span may be absurd. What
        /// is not acceptable is not knowing which. Written here rather than only
        /// to the log so the rate is countable from the file later, and the log
        /// truncates at 1 MB.
        var skipped: String?
    }

    /// The store's own directories, made on demand.
    ///
    /// Nothing creates `voice/` at install: it appears the first time something
    /// is learnt, so a machine that has never corrected anything has no empty
    /// folder to explain.
    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// One more line on the end of `observations.jsonl`.
    ///
    /// `O_APPEND`, for the reason `Trace.append` gives: seeking to the end and
    /// then writing is two steps and two processes can interleave them. The app
    /// and a mining script both write here.
    static func append(_ observation: Observation) throws {
        try makeDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = try encoder.encode(observation)
        data.append(0x0A)

        let fd = open(observationsURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw StoreError.cannotWrite(observationsURL) }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            guard write(fd, base, buffer.count) == buffer.count else {
                throw StoreError.cannotWrite(observationsURL)
            }
        }
    }

    enum StoreError: LocalizedError {
        case cannotWrite(URL)

        var errorDescription: String? {
            switch self {
            case .cannotWrite(let url):
                return "could not write \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Samples

    /// Where a term's samples live. The folder is the term as `vocabulary.yaml`
    /// spells it, so `--forget` can name it back.
    static func samples(for term: String) -> URL {
        samplesDirectory.appendingPathComponent(term, isDirectory: true)
    }

    /// The wav files of one term, oldest first by name.
    ///
    /// By name rather than by modification date: a copied archive has every
    /// file stamped with the moment it was copied, and the name carries the
    /// sequence the recording was written in.
    static func sampleFiles(of term: String) -> [String] {
        let inside = (try? FileManager.default.contentsOfDirectory(
            atPath: samples(for: term).path
        )) ?? []
        return inside.filter { $0.hasSuffix(".wav") }.sorted()
    }

    /// A free filename for a new sample of `term`, in the shape mining writes:
    /// `NN-rendering.wav`, numbered above everything already there.
    static func nextSampleName(for term: String, heard: String) -> String {
        let slug = heard.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let used = sampleFiles(of: term).compactMap { name -> Int? in
            Int(name.prefix(while: { $0.isNumber }))
        }
        let next = (used.max() ?? -1) + 1
        return String(format: "%02d-%@.wav", next, slug.isEmpty ? "rendering" : slug)
    }

    /// Holds a term to `perTermSampleCap` files, and says what went.
    ///
    /// **The oldest unconfirmed sample goes first.** A sample whose observation
    /// says `from: correction` is one a person looked at a transcript and
    /// labelled by hand; a mined one is a guess made from a decode that may
    /// itself have been wrong. When only confirmed samples are left the oldest
    /// of those goes, because a cap that refuses to act is not a cap.
    ///
    /// Never silent. Every removal is returned, and every caller logs it.
    @discardableResult
    static func enforceCap(on term: String, cap: Int = perTermSampleCap) -> [(file: String, why: String)] {
        var files = sampleFiles(of: term)
        guard files.count > cap else { return [] }

        // Which samples a person confirmed, from the observations that name
        // them. A file with no observation is unconfirmed by default — it is
        // audio nobody wrote anything down about.
        var confirmed: Set<String> = []
        for observation in observations() where observation.from == "correction" {
            if let sample = observation.sample {
                confirmed.insert((sample as NSString).lastPathComponent)
            }
        }

        var removed: [(file: String, why: String)] = []
        let store = FileManager.default
        // Unconfirmed first, oldest first within each group.
        let order = files.filter { !confirmed.contains($0) } + files.filter { confirmed.contains($0) }
        for name in order {
            guard files.count > cap else { break }
            let why = confirmed.contains(name)
                ? "oldest confirmed — every sample of this term is confirmed"
                : "oldest unconfirmed"
            try? store.removeItem(at: samples(for: term).appendingPathComponent(name))
            files.removeAll { $0 == name }
            removed.append((name, why))
        }
        return removed
    }

    /// Every observation on file, oldest first.
    ///
    /// A line that does not parse is skipped, not thrown. This file is appended
    /// to by more than one thing, and a half-written last line — a crash
    /// mid-append — must not make the whole archive unreadable.
    static func observations() -> [Observation] {
        guard let text = try? String(contentsOf: observationsURL, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Observation.self, from: data)
        }
    }

    /// What the store holds, per term, for `--check-config` and `--forget`.
    static func counts() -> [(term: String, observations: Int, samples: Int)] {
        var seen: [String: Int] = [:]
        for observation in observations() {
            seen[observation.term, default: 0] += 1
        }
        var kept: [String: Int] = [:]
        for name in termFolders() {
            let inside = (try? FileManager.default.contentsOfDirectory(
                atPath: samplesDirectory.appendingPathComponent(name).path
            )) ?? []
            kept[name] = inside.filter { $0.hasSuffix(".wav") }.count
        }
        return Set(seen.keys).union(kept.keys).sorted().map {
            (term: $0, observations: seen[$0] ?? 0, samples: kept[$0] ?? 0)
        }
    }

    /// The term folders under `samples/`, directories only.
    ///
    /// A stray file — `.DS_Store` is the one that turns up — is not a term, and
    /// listing it as one would offer `--forget .DS_Store`.
    private static func termFolders() -> [String] {
        let files = FileManager.default
        return ((try? files.contentsOfDirectory(atPath: samplesDirectory.path)) ?? [])
            .filter { name in
                var directory: ObjCBool = false
                let path = samplesDirectory.appendingPathComponent(name).path
                return files.fileExists(atPath: path, isDirectory: &directory)
                    && directory.boolValue
            }
    }

    /// Everything this store knows about one term, gone.
    ///
    /// Returns what was removed, so the caller can say it out loud — including
    /// the folder names, because matching is case-insensitive and a person
    /// typing `--forget praisy` should be told `samples/Praisy/` is what went.
    @discardableResult
    static func forget(
        _ term: String
    ) throws -> (observations: Int, samples: Int, folders: [String]) {
        let files = FileManager.default
        var dropped = 0
        if let text = try? String(contentsOf: observationsURL, encoding: .utf8) {
            let decoder = JSONDecoder()
            // Kept as text. A row this version cannot decode is a row a later
            // version wrote, and rewriting the file through this struct would
            // silently drop every field it does not know about.
            let kept = text.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
                guard let data = line.data(using: .utf8),
                      let observation = try? decoder.decode(Observation.self, from: data),
                      observation.term.caseInsensitiveCompare(term) == .orderedSame
                else { return true }
                dropped += 1
                return false
            }
            if dropped > 0 {
                let rebuilt = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
                try rebuilt.write(to: observationsURL, atomically: true, encoding: .utf8)
            }
        }

        var removed = 0
        var folders: [String] = []
        for name in termFolders() where name.caseInsensitiveCompare(term) == .orderedSame {
            let folder = samplesDirectory.appendingPathComponent(name)
            removed += ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".wav") }.count
            try files.removeItem(at: folder)
            folders.append(name)
        }
        return (dropped, removed, folders)
    }
}
