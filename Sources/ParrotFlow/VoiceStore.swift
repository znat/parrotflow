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
/// This PR creates and reads the store. Writing on a correction is PR 8.
enum VoiceStore {

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

    /// Cut spans only — a few hundred KB each. Never the whole dictation: the
    /// clip is already on disk once, and a second copy of it in the config
    /// directory is an archive nobody asked for.
    static func samples(for term: String) -> URL {
        samplesDirectory.appendingPathComponent(term, isDirectory: true)
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
        let files = FileManager.default
        var kept: [String: Int] = [:]
        for name in (try? files.contentsOfDirectory(atPath: samplesDirectory.path)) ?? [] {
            let inside = (try? files.contentsOfDirectory(
                atPath: samplesDirectory.appendingPathComponent(name).path
            )) ?? []
            kept[name] = inside.filter { $0.hasSuffix(".wav") }.count
        }
        return Set(seen.keys).union(kept.keys).sorted().map {
            (term: $0, observations: seen[$0] ?? 0, samples: kept[$0] ?? 0)
        }
    }

    /// Everything this store knows about one term, gone.
    ///
    /// Returns what was removed, so the caller can say it out loud. Matching is
    /// case-insensitive: a person typing `--forget praisy` means the term.
    @discardableResult
    static func forget(_ term: String) throws -> (observations: Int, samples: Int) {
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
        for name in (try? files.contentsOfDirectory(atPath: samplesDirectory.path)) ?? []
        where name.caseInsensitiveCompare(term) == .orderedSame {
            let folder = samplesDirectory.appendingPathComponent(name)
            removed += ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".wav") }.count
            try files.removeItem(at: folder)
        }
        return (dropped, removed)
    }
}
