import Foundation

/// `--route "<what you'd say>"` — runs the router from the terminal and prints
/// which capability it picked, without running it.
///
/// The routing decision is otherwise only observable by speaking and watching
/// what happens, which conflates "routed wrong" with "the prompt is bad". This
/// separates them, and it is what `scripts/check-routing.sh` drives.
///
/// `--keyed` scores the other path — tap-and-hold, where a key said this was
/// an instruction. There is no model router at all: a name anywhere in the
/// sentence wins, and everything else is the catch-all. It answers a different
/// question from the default, so it has a set of its own —
/// `scripts/check-keyed.sh`.
enum RouteTestCommand {

    static func run(text: String, quiet: Bool = false, keyed: Bool = false) -> Int32 {
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

        if let match = Router.local(
            instruction: instruction, catalogue: catalogue, anywhere: keyed
        ) {
            print(quiet ? match.name : "→ \(match.name)  (named outright, no model)")
            return 0
        }

        // Keyed: no router, so the answer is already known. Named nothing means
        // the catch-all, and the only way to get NONE is to have turned it off.
        if keyed {
            guard config.freeForm else {
                print(quiet ? "NONE" : "→ NONE  (named nothing, and the catch-all is off)")
                return 0
            }
            print(quiet ? "ANY" : "→ ANY  (named nothing, straight to the catch-all — no model)")
            return 0
        }

        guard config.llmEnabled else {
            print("✗ needs a model, but `models:` defines none")
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
