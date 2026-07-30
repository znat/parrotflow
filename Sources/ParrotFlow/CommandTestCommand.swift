import Foundation

/// `--command "<what you'd say>"` — runs the wake-phrase router from the
/// terminal and prints what it resolved to, without saving anything.
///
/// Voice commands are otherwise only testable by speaking, which makes
/// iterating on the prompt slow and makes regressions easy to miss.
enum CommandTestCommand {

    static func run(text: String) -> Int32 {
        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        let phrase = config.transcription.correctionPhrase
        print("wake phrase: \"\(phrase)\"")

        guard let command = strip(phrase: phrase, from: text) else {
            print("→ not a command; this would be dictated as normal text")
            return 0
        }
        print("command:     \"\(command)\"")

        if let local = VoiceCommand.local(from: command) {
            print("→ matched locally, no model needed")
            describe(local)
            return 0
        }

        guard config.llm.enabled else {
            print("→ needs the LLM, but llm.enabled is false")
            return 1
        }

        let llmConfig = LocalLLM.Config(
            endpoint: config.llm.endpoint,
            model: config.llm.model,
            timeout: config.llm.timeoutSeconds
        )
        if let spelled = VoiceCommand.spelledOutWord(in: command) {
            print("spelled-out: \"\(spelled)\"  (taken from the text, not the model)")
        }

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            let started = Date()
            do {
                let result = try await VoiceCommand.interpret(
                    command: command, lastTranscript: nil, config: llmConfig
                )
                print(String(format: "→ %@ in %.2fs", config.llm.model, Date().timeIntervalSince(started)))
                describe(result)
            } catch {
                print("✗ \(error.localizedDescription)")
                code = 1
            }
            done.signal()
        }
        done.wait()
        return code
    }

    private static func describe(_ command: VoiceCommand) {
        switch command {
        case .openCorrectionPanel:
            print("   action: open the correction panel")
        case .addRule(let heard, let corrected):
            print("   action: add rule   \(heard) → \(corrected)")
        case .unrecognised(let text):
            print("   action: none — didn't understand \"\(text)\"")
        }
    }

    /// Mirrors AppDelegate's prefix match.
    private static func strip(phrase: String, from text: String) -> String? {
        func normalise(_ value: String) -> [String] {
            value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
                .joined()
                .split(separator: " ")
                .map(String.init)
        }
        let phraseWords = normalise(phrase)
        let spokenWords = text.split(separator: " ").map(String.init)
        let normalised = normalise(text)
        guard !phraseWords.isEmpty, phraseWords.count <= normalised.count,
              Array(normalised.prefix(phraseWords.count)) == phraseWords else { return nil }
        guard spokenWords.count == normalised.count else {
            return normalised.dropFirst(phraseWords.count).joined(separator: " ")
        }
        return spokenWords.dropFirst(phraseWords.count)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
