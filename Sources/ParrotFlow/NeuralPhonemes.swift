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
        if await isReady() { return }
        progress?("sound model")
        let directory = try TtsCacheDirectory.ensure().appendingPathComponent("Models")
        try await ModelHub.download(
            .kokoro, to: directory,
            additionalModelNames: ModelNames.MultilingualG2P.requiredModels
        )
        try await MultilingualG2PModel.shared.ensureModelsAvailable()
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
    private static let cacheLock = NSLock()
    private static let saveQueue = DispatchQueue(label: "com.parrotflow.phonemes")

    /// Keyed by the model, because an entry is only right for the weights that
    /// wrote it.
    private static var cacheURL: URL {
        AppVariant.supportDirectory
            .appendingPathComponent("phonemes-multilingual-g2p.json")
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

    private static func readCache() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func writeCache(_ table: [String: [String: String]]) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(table).write(to: cacheURL, options: .atomic)
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
