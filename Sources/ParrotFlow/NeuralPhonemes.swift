import CryptoKit
import Foundation
import FluidAudio

/// How a word sounds, worked out by a model rather than by rules.
///
/// The second ear beside `Phonemes`, which is espeak-ng. They are not a
/// replacement for each other and the measurement is why — on this speaker's
/// 20891 dictations, at floor 0.85, scoring every 1- and 2-word window:
///
///     converter   windows   right   wrong
///     espeak         41       36      5
///     this           46       39      7
///     both           62       54      8
///
/// Three false windows more, eighteen true ones. They fail differently too,
/// which is the strongest sign they are worth having together: this one
/// invents `praising -> Praisy`, espeak invents `and re -> Andrey`, and
/// neither makes the other's mistake.
///
/// What each finds alone says why. This model reads the whole string at once,
/// so it hears through a word boundary the recogniser invented — `Priss y`
/// (259 times), `O lama`, `au lama`, `press a`, `versol`. espeak applies
/// letter-to-sound rules, so it is better on a spelling nobody has ever
/// written — `geler` (45 times), `Prazi`, `Ghost E`, `Jemma`.
///
/// **This one is the default and espeak is the improvement.** It arrives as a
/// model download like every other, carries no licence to pass on, and covers
/// nine languages. espeak is a separate GPL-3 program that has to be installed
/// by hand, and with this in place its absence costs coverage rather than the
/// whole feature.
enum NeuralPhonemes {

    /// The row the setup screen draws for it. Named for the model rather than
    /// for the job: it is CharsiuG2P, run through FluidAudio's Core ML build.
    static let soundDownload = ModelDownload(
        id: "sound", name: "CharsiuG2P", megabytes: 81, peak: 81,
        group: .sound, blocking: false,
        costOfFailure: "your terms are matched by spelling until it arrives"
    )

    /// The languages the model has, in the app's own terms. Nil for a
    /// language it does not speak — every other one it would guess at.
    static func language(_ code: String) -> MultilingualG2PLanguage? {
        switch code {
        case "en": return .americanEnglish
        case "fr": return .french
        default: return nil
        }
    }

    /// True when the two model files are already on disk and loaded.
    static func isReady() async -> Bool {
        do {
            try await MultilingualG2PModel.shared.ensureModelsAvailable()
            return true
        } catch {
            return false
        }
    }

    /// Fetches the encoder and decoder if they are not there yet.
    ///
    /// They live in FluidAudio's own TTS cache, beside the voices, because
    /// that is where `MultilingualG2PModel` looks for them and nothing here
    /// should teach it a second path.
    static func download(progress: (@Sendable (String) -> Void)? = nil) async throws {
        if await isReady() {
            ModelDownloads.report(soundDownload.id, .installed)
            return
        }
        progress?("sound model")
        // No percentage: `ModelHub.download` reports none, and a number nobody
        // measured is worse than a spinner.
        ModelDownloads.report(soundDownload.id, .downloading(percent: nil))
        do {
            let directory = try TtsCacheDirectory.ensure().appendingPathComponent("Models")
            try await ModelHub.download(
                .kokoro, to: directory,
                additionalModelNames: ModelNames.MultilingualG2P.requiredModels
            )
            try await MultilingualG2PModel.shared.ensureModelsAvailable()
            ModelDownloads.report(soundDownload.id, .installed)
        } catch {
            ModelDownloads.report(
                soundDownload.id,
                .failed(ModelDownloads.failure(error, needs: soundDownload.peakLabel))
            )
            throw error
        }
    }

    // MARK: - what the model has already said

    /// The answers so far, by language and then by word, kept between launches.
    ///
    /// The sound pass asks about every 1- and 2-word window of the sentence,
    /// and each miss is one sequence-to-sequence call. Held only in memory this
    /// table started empty at every launch, so every session paid for its own
    /// warm-up. Warmed on 1211 English dictations from the archive and asked
    /// the next 135, 51.5% of windows were already known: 6.7 model calls a
    /// dictation instead of 13.7.
    ///
    /// No cap. Those 1211 dictations produce 10305 entries, about 460 KB, and
    /// an entry is a word and a short string of IPA.
    private static var cache: [String: [String: String]] = [:]
    private static var loadedFromDisk = false
    private static var savePending = false
    /// Worked out once per launch. The files do not move under a running app.
    private static var weights: String?
    private static let cacheLock = NSLock()
    private static let saveQueue = DispatchQueue(label: "com.parrotflow.phonemes")

    /// Named for the model. The name says which model wrote the table and
    /// nothing about which weights, which is what `weightsFingerprint` is for.
    private static var cacheURL: URL {
        AppVariant.supportDirectory
            .appendingPathComponent("phonemes-multilingual-g2p.json")
    }

    /// The weights on disk, hashed. Every byte of both G2P bundles, each file
    /// preceded by its path under the cache root so a file moving counts too.
    ///
    /// The table has to be thrown away when the model changes, and there is
    /// nothing cheaper to hang that on. FluidAudio publishes no version for
    /// these models, `ModelNames.MultilingualG2P` is two file names and no
    /// revision, and the download leaves no manifest — the `config.json` beside
    /// the bundles is `{}`. The bytes are the only identity there is.
    ///
    /// Path, size and modification date were tried first and are not enough:
    /// weights can be replaced with different bytes of the same size and the
    /// dates put back, and the table would then be kept against a model that no
    /// longer agrees with it. The damage is a mixed table rather than an old
    /// one — a window read by the new model scored against a term read by the
    /// old one over a 0.85 floor, with neither reading wrong on its own.
    ///
    /// One pass over 79 MB, once per launch — the answer is held in `weights`
    /// for the life of the process. It is cheaper than it sounds because the
    /// files are in the page cache by the time anything asks: the model has
    /// just been loaded. `--sound` end to end is 0.37-0.44s with this and was
    /// 0.43s without it, which is inside the noise. A genuinely cold read costs
    /// about a second, and `AppDelegate` pays it on the same background task
    /// that fetches the model, so a dictation waits on it only if one is
    /// started before that task gets there.
    ///
    /// Streamed in 1 MB chunks. The point is a digest, not 79 MB resident.
    ///
    /// Nil when both bundles are not there to read, and then nothing is
    /// written: a table that cannot be keyed cannot be trusted next launch.
    private static func weightsFingerprint() -> String? {
        cacheLock.lock()
        let known = weights
        cacheLock.unlock()
        if let known { return known }

        guard let root = try? TtsCacheDirectory.ensure() else { return nil }
        let wanted = ModelNames.MultilingualG2P.requiredModels
        let manager = FileManager.default
        guard let walk = manager.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }

        var seen: Set<String> = []
        var files: [URL] = []
        for case let url as URL in walk where wanted.contains(url.lastPathComponent) {
            walk.skipDescendants()
            seen.insert(url.lastPathComponent)
            guard let inside = manager.enumerator(
                at: url, includingPropertiesForKeys: nil
            ) else { return nil }
            for case let file as URL in inside {
                var directory: ObjCBool = false
                guard manager.fileExists(atPath: file.path, isDirectory: &directory),
                      !directory.boolValue
                else { continue }
                files.append(file)
            }
        }
        guard seen == wanted, !files.isEmpty else { return nil }

        var hasher = SHA256()
        // Sorted, so the digest does not depend on the order the enumerator
        // happened to walk in. The path goes in with the bytes: both bundles
        // hold a `model.mil` and a `weights/weight.bin`.
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(file.path.dropFirst(root.path.count).utf8))
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        let mark = String(
            hasher.finalize().compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        )
        cacheLock.lock()
        weights = mark
        cacheLock.unlock()
        return mark
    }

    /// Reads the table now, so the first dictation of the session does not.
    ///
    /// Safe to call from anywhere and safe to call twice. Called at launch and
    /// again at the top of `of`, for the run where the launch call has not
    /// landed yet.
    static func warmCache() {
        cacheLock.lock()
        let already = loadedFromDisk
        cacheLock.unlock()
        guard !already else { return }

        let disk = readCache()
        cacheLock.lock()
        if !loadedFromDisk {
            // Anything computed while the file was being read wins. It came
            // from the same weights and it is the later answer.
            for (language, words) in disk {
                cache[language] = words.merging(cache[language] ?? [:]) { _, live in live }
            }
            loadedFromDisk = true
        }
        cacheLock.unlock()
    }

    /// Writes the table back, off the caller's thread and one write at a time.
    ///
    /// A dictation adds a handful of entries and the whole table is re-encoded,
    /// so this must not run on the path it exists to shorten. A second request
    /// arriving while one is queued is dropped rather than queued behind it:
    /// the block reads the table when it runs, so it already carries whatever
    /// the second caller added.
    private static func scheduleSave() {
        cacheLock.lock()
        let pending = savePending
        savePending = true
        cacheLock.unlock()
        guard !pending else { return }

        saveQueue.async {
            cacheLock.lock()
            savePending = false
            let snapshot = cache
            cacheLock.unlock()
            writeCache(snapshot)
        }
    }

    /// Waits for a queued write to land.
    ///
    /// For a process that ends: a CLI command, or the app quitting. Without it
    /// a `--sound` run asks the model for words it will ask for again next
    /// time, because it exits before the write does.
    static func flushCache() {
        saveQueue.sync {}
    }

    /// The file: the weights that wrote the table, and the table.
    private struct Stored: Codable {
        let weights: String
        let words: [String: [String: String]]
    }

    private static func readCache() -> [String: [String: String]] {
        guard let here = weightsFingerprint(),
              let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [:] }
        guard stored.weights == here else {
            Log.write("phonemes: the sound model has changed since these"
                + " pronunciations were saved; starting again")
            return [:]
        }
        return stored.words
    }

    private static func writeCache(_ table: [String: [String: String]]) {
        guard let here = weightsFingerprint() else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Stored(weights: here, words: table))
                .write(to: cacheURL, options: .atomic)
        } catch {
            // The table is still in memory for this run and the next run asks
            // the model again. Not worth failing a dictation over.
            Log.write("phonemes: could not cache (\(error.localizedDescription))")
        }
    }

    /// The IPA of every word given. Absent from the result means the model had
    /// nothing to say about it.
    ///
    /// One word per call by construction — the model is sequence to sequence
    /// and takes one string — so this is the slower of the two ears. The cache
    /// is what makes that affordable: an ordinary dictation asks about words
    /// it has asked about before, this launch or a previous one.
    static func of(
        _ words: [String], language: MultilingualG2PLanguage
    ) async -> [String: String] {
        guard await isReady() else { return [:] }
        warmCache()
        let table = language.rawValue
        var answer: [String: String] = [:]
        var added = false
        for word in words {
            let clean = Phonemes.cleaned(word)
            guard !clean.isEmpty else { continue }
            cacheLock.lock()
            let known = cache[table]?[clean]
            cacheLock.unlock()
            if let known {
                if !known.isEmpty { answer[word] = known }
                continue
            }
            let said: String
            do {
                said = try await MultilingualG2PModel.shared
                    .phonemize(word: clean, language: language)?
                    .joined() ?? ""
            } catch {
                // Not an answer, so it is not written down. A call that threw
                // is a model that was busy or half-loaded, and the table now
                // outlives the process: caching its silence would hide this
                // word from the sound pass at every future launch as well.
                // `nil` above is the other case — the model saying it has
                // nothing for this word — and that is worth keeping.
                continue
            }
            // Stress and length go, exactly as they do for espeak — the two
            // scores are compared against one floor, so they have to be the
            // same kind of string.
            let clipped = Phonemes.clip(said)
            cacheLock.lock()
            // Empty is an answer and it is kept. A word the model has nothing
            // to say about costs a call to find out, and it costs the same
            // call every time it is asked again.
            cache[table, default: [:]][clean] = clipped
            cacheLock.unlock()
            added = true
            if !clipped.isEmpty { answer[word] = clipped }
        }
        if added { scheduleSave() }
        return answer
    }
}
