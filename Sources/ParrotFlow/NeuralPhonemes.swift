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

    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// The IPA of every word given. Absent from the result means the model had
    /// nothing to say about it.
    ///
    /// One word per call by construction — the model is sequence to sequence
    /// and takes one string — so this is the slower of the two ears. The cache
    /// is what makes that affordable: an ordinary dictation asks about words
    /// it has asked about before.
    static func of(
        _ words: [String], language: MultilingualG2PLanguage
    ) async -> [String: String] {
        guard await isReady() else { return [:] }
        var answer: [String: String] = [:]
        for word in words {
            let clean = Phonemes.cleaned(word)
            guard !clean.isEmpty else { continue }
            let key = "\(language.rawValue)\u{0}\(clean)"
            cacheLock.lock()
            let known = cache[key]
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
                said = ""
            }
            // Stress and length go, exactly as they do for espeak — the two
            // scores are compared against one floor, so they have to be the
            // same kind of string.
            let clipped = Phonemes.clip(said)
            cacheLock.lock()
            cache[key] = clipped
            cacheLock.unlock()
            if !clipped.isEmpty { answer[word] = clipped }
        }
        return answer
    }
}
