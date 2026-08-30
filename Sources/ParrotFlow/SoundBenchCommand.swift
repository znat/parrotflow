import Foundation

/// `--phonemes <word> [word …]` — what each ear hears, side by side.
///
/// The diagnostic behind every number in `NeuralPhonemes`. It fetches the
/// model if it is missing, so it is also how the download is checked by hand.
enum SoundBenchCommand {

    static func run(_ words: [String], language: String) async -> Int32 {
        if let named = NeuralPhonemes.language(language) {
            do {
                try await NeuralPhonemes.download { Log.write("phonemes: \($0)") }
            } catch {
                print("model: \(error.localizedDescription)")
            }
            let model = await NeuralPhonemes.of(words, language: named)
            let rules = Phonemes.of(words, voice: language == "fr" ? "fr" : "en-us")
            func pad(_ text: String, _ width: Int) -> String {
                text.count >= width ? text + "  "
                    : text + String(repeating: " ", count: width - text.count)
            }
            print(pad("word", 20) + pad("model", 18) + "espeak")
            for word in words {
                print(pad(word, 20) + pad(model[word] ?? "—", 18) + (rules[word] ?? "—"))
            }
            return 0
        }
        print("no model for language \(language)")
        return 2
    }
}
