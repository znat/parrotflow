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

        // The built-in is reachable by name here although it is not in the
        // catalogue, because this command exists to exercise a prompt on its
        // own and that one has the largest validation set behind it. Config
        // first, so a prompt of your own called `anything` still wins.
        let named = config.prompts.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        } ?? (FreeForm.name.caseInsensitiveCompare(name) == .orderedSame ? FreeForm.prompt : nil)

        guard let prompt = named else {
            let known = (config.prompts.map(\.name) + [FreeForm.name]).joined(separator: ", ")
            print("✗ no prompt named \"\(name)\" — have: \(known)")
            return 1
        }

        guard config.llmEnabled else {
            print("✗ llm.enabled is false")
            return 1
        }

        let llmConfig = config.model(for: .general)

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
                                 llmConfig.model, Date().timeIntervalSince(started)))
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
