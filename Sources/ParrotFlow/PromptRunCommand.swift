import Foundation

/// `--prompt <name> "<instruction>" "<text>"` — runs one prompt and prints the
/// result, applying nothing.
///
/// Routing being right says nothing about whether a prompt behaves, and the two
/// fail in ways that look identical from the outside. This exercises the prompt
/// on its own, and is what scripts/check-grammar.sh drives.
enum PromptRunCommand {

    static func run(name: String, instruction: String, text: String, quiet: Bool = false) -> Int32 {
        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        guard let prompt = config.prompts.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            let known = config.prompts.map(\.name).joined(separator: ", ")
            print("✗ no prompt named \"\(name)\"" + (known.isEmpty ? "" : " — have: \(known)"))
            return 1
        }

        guard config.llm.enabled else {
            print("✗ llm.enabled is false")
            return 1
        }

        let llmConfig = LocalLLM.Config(
            endpoint: config.llm.endpoint,
            model: config.llm.model,
            timeout: config.llm.timeoutSeconds,
            keepLoaded: config.llm.keepLoaded
        )

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            let started = Date()
            do {
                let result = try await PromptRunner.run(
                    prompt: prompt, instruction: instruction, text: text, config: llmConfig
                )
                if quiet {
                    print(result)
                } else {
                    print("prompt:      \(prompt.name)\(prompt.confirm ? "  (confirm on)" : "")")
                    print("instruction: \"\(instruction)\"")
                    print("in:          \(text)")
                    print("out:         \(result)")
                    print(String(format: "             %@ in %.2fs",
                                 config.llm.model, Date().timeIntervalSince(started)))
                }
            } catch {
                print("✗ \(error.localizedDescription)")
                code = 1
            }
            done.signal()
        }
        done.wait()
        return code
    }
}
