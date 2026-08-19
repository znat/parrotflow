import Foundation

/// `--command "<what you'd say>"` — runs the wake-phrase router from the
/// terminal and prints what it resolved to, without saving anything.
///
/// Voice commands are otherwise only testable by speaking, which makes
/// iterating on the prompt slow and makes regressions easy to miss.
///
/// `--phrases "hey parrot,by the way parrot"` stands in for the configured
/// list, the same way `--lang` stands in for the configured languages: a case
/// file can then state the environment it assumes instead of inheriting
/// whichever phrases happen to be on this machine.
enum CommandTestCommand {

    static func run(
        text: String, lastTranscript: String? = nil, phrases override: [String]? = nil
    ) -> Int32 {
        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        let phrases = override ?? config.transcription.activationPhrases
        print("wake phrase: \(phrases.map { "\"\($0)\"" }.joined(separator: ", "))")
        if let lastTranscript {
            print("context:     \"\(lastTranscript)\"")
        }

        guard let command = VoiceCommand.commandAfterWakePhrase(text, phrases: phrases) else {
            // A phrase found mid-sentence is an instruction about the words in
            // front of it, not about the selection — printed here rather than
            // in a command of its own, because "what would this utterance do"
            // has one answer and wants one place to ask it.
            if let split = VoiceCommand.inlineInstruction(text, phrases: phrases) {
                print("text:        \"\(split.text)\"")
                print("instruction: \"\(split.instruction)\"")
                print("→ an instruction inside a dictation; the text above is what it edits")
                return 0
            }
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

        let llmConfig = config.model(for: .general)
        let spelled = VoiceCommand.spellingSegments(in: command)
        if !spelled.isEmpty {
            let shown = spelled
                .map { "\"\($0.letters)\"\($0.letterish ? "" : " (not read out as letters)")" }
                .joined(separator: ", ")
            print("spelled-out: \(shown)  (taken from the text, not the model)")
        }

        // Resolved the same way the app resolves it, from the transcript. When
        // this harness and the app disagree about anything, the harness is
        // testing code nobody runs.
        let language = DictationLanguage.forCorrection(
            transcript: lastTranscript, allowed: config.transcription.languages
        )
        print("language:    \(language)  (of \(config.transcription.languages.joined(separator: ", ")))")

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            let started = Date()
            do {
                let result = try await VoiceCommand.interpret(
                    command: command, lastTranscript: lastTranscript,
                    language: language, config: llmConfig
                )
                print(String(format: "→ %@ in %.2fs", llmConfig.model, Date().timeIntervalSince(started)))
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
        case .addRules(let rules):
            for rule in rules {
                print("   action: add rule   \(rule.heard) → \(rule.corrected)")
            }
        case .undo:
            print("   action: undo the last substitution")
        case .unrecognised(let text):
            print("   action: none — didn't understand \"\(text)\"")
        }
    }

}
