import Foundation

/// `--route "<what you'd say>"` — runs the router from the terminal and prints
/// which capability it picked, without running it.
///
/// The routing decision is otherwise only observable by speaking and watching
/// what happens, which conflates "routed wrong" with "the prompt is bad". This
/// separates them, and it is what `scripts/check-routing.sh` drives.
enum RouteTestCommand {

    static func run(text: String, quiet: Bool = false) -> Int32 {
        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }

        let catalogue = Catalogue(transforms: config.transforms)
        let phrases = config.transcription.activationPhrases

        // The wake phrase is stripped first, exactly as the app does it, so a
        // case written the way you'd actually say it still exercises the
        // router rather than silently testing the wrong string.
        let instruction = VoiceCommand.commandAfterWakePhrase(text, phrases: phrases) ?? text

        if !quiet {
            print("catalogue:   \(catalogue.names.joined(separator: ", "))")
            print("instruction: \"\(instruction)\"")
        }

        if let match = Router.local(instruction: instruction, catalogue: catalogue) {
            print(quiet ? match.name : "→ \(match.name)  (named outright, no model)")
            return 0
        }

        guard config.llm.enabled else {
            print("✗ needs the LLM, but llm.enabled is false")
            return 1
        }

        let llmConfig = config.model(for: .router)

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            let started = Date()
            do {
                let decision = try await Router.route(
                    instruction: instruction,
                    catalogue: catalogue,
                    freeForm: config.freeForm,
                    config: llmConfig
                )
                let elapsed = Date().timeIntervalSince(started)
                let timing = String(format: "(%@ in %.2fs)", llmConfig.model, elapsed)
                switch decision {
                case .matched(let capability):
                    print(quiet ? capability.name : "→ \(capability.name)  \(timing)")
                case .anything:
                    // ANY rather than the prompt's name, because what is being
                    // reported is the router's answer. Which prompt runs after
                    // it is `--prompt anything`'s question.
                    print(quiet ? "ANY" : "→ ANY  \(timing)  an edit, but no prompt covers it")
                case .none:
                    print(quiet ? "NONE" : "→ NONE  \(timing)")
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
