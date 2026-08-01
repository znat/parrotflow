import AVFoundation
import Foundation
import Yams

enum CheckConfigCommand {

    /// Returns the process exit code: 0 if the config is usable, 1 otherwise.
    static func run() -> Int32 {
        print("config: \(ConfigStore.fileURL.path)")

        let config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            print("  ✗ \(describe(error))")
            return 1
        }

        var ok = true

        // Hotkey
        let mode = config.hotkey.mode == .toggle ? "toggle" : "push-to-talk"
        if let modifierKey = ModifierKey(name: config.hotkey.key) {
            print("  ✓ hotkey            \(modifierKey.displayName)  (\(mode), polled)")
            if !config.hotkey.modifiers.isEmpty {
                print("  · note              hotkey.modifiers is ignored for a bare modifier key")
            }
        } else if KeyCodes.code(for: config.hotkey.key) == nil {
            print("  ✗ hotkey.key: \"\(config.hotkey.key)\" is not a known key name")
            ok = false
        } else if KeyCodes.carbonModifiers(config.hotkey.modifiers) == 0 {
            print("  ✗ hotkey.modifiers: need at least one of command, control, option, shift")
            ok = false
        } else {
            let shortcut = KeyCodes.displayString(key: config.hotkey.key, modifiers: config.hotkey.modifiers)
            print("  ✓ hotkey            \(shortcut)  (\(mode), Carbon)")
        }

        // Audio
        print("  ✓ sample rate       \(Int(config.audio.sampleRate)) Hz mono")
        print("  ✓ output dir        \(config.resolvedOutputDir.path)")
        print("  ✓ min duration      \(config.audio.minDurationSeconds)s")
        print("  · speech gate       \(config.audio.speechGate ? "on" : "off")")
        print("  · feedback          sound=\(config.feedback.sound) overlay=\(config.feedback.overlay)")

        // Transcription — printed so a mis-decoded config is visible rather
        // than silently falling back to "no vocabulary".
        let transcription = config.transcription
        print("  · transcription     \(transcription.enabled ? "enabled" : "disabled")")
        if transcription.enabled {
            let mode = transcription.insertMode == .paste
                ? "paste into frontmost app (needs Accessibility)"
                : "copy to clipboard"
            print("  · insert mode       \(mode)")
            print("  · wake phrase       \"\(transcription.activationPhrase)\"")
            print("  · rewrite line      \(transcription.rewriteLine ? "on" : "off (terminals can't be edited without it)")")
            // The pipeline, per language, because "why was this not
            // converted" is a question about the order and not about a
            // setting any more.
            for language in transcription.languages {
                let pipeline = Pipeline.resolved(config: config, language: language)
                let source = transcription.pipelines[language] != nil ? language
                    : (transcription.pipelines["default"] != nil
                        ? "default" : "nothing configured, so every stage")
                // An empty pipeline is a choice, not a blank: printing
                // nothing there reads as a display fault rather than as the
                // answer to "why did none of this run".
                // Conditions are printed with the stage they gate. A pipeline
                // that reads as three stages when one of them almost never
                // runs is a pipeline that explains nothing.
                let stages = pipeline.steps.isEmpty
                    ? "nothing — the list is empty"
                    : pipeline.steps.map { step -> String in
                        var described = step.stage.name
                        if let prompt = step.prompt { described += " \(prompt)" }
                        if let when = step.when { described += " when \(when)" }
                        if let unless = step.unless { described += " unless \(unless)" }
                        return described
                    }.joined(separator: " → ")
                print("  · pipeline \(language)        \(stages)  (\(source))")
            }
        }

        // A key that no longer does anything is worse than a key that is
        // wrong: nothing fails, and two passes quietly stop running. So it is
        // an error, with the replacement spelled out.
        for problem in config.problems() {
            print("  ✗ \(problem)")
            ok = false
        }
        if !transcription.retired.isEmpty {
            print("      pipelines:")
            print("        default: [\(Pipeline.everything.stages.map(\.name).joined(separator: ", "))]")
        }

        // What "hey parrot" can reach. Printed even when `prompts:` is empty,
        // because the built-ins are the answer to "why did it do that" as
        // often as a prompt of your own is.
        let catalogue = Catalogue(prompts: config.prompts)
        print("  ✓ capabilities      \(catalogue.capabilities.count) reachable by \"\(transcription.activationPhrase)\"")
        for capability in catalogue.capabilities {
            let kind = capability.isTransform ? "prompt " : "built-in"
            print("      \(kind)  \(capability.name) — \(capability.describedAs)")
        }
        // Not one of the capabilities above — the router reaches it by
        // answering ANY, not by picking it off the list — so it is printed
        // apart from them rather than pretending to be a catalogue entry.
        if config.freeForm {
            print("      free-form  \(FreeForm.name) — \(FreeForm.prompt.description)")
        } else {
            print("  · free_form         off — an instruction no prompt covers is refused")
        }

        for prompt in config.prompts where prompt.description.isEmpty {
            print("  ✗ prompt \"\(prompt.name)\" has no description; the router cannot pick it")
            ok = false
        }

        // LLM — only reachability is checked here; --command exercises it.
        if config.llm.enabled {
            print("  · llm               \(config.llm.model) at \(config.llm.endpoint)")
            print("  · keep loaded       \(config.llm.keepLoaded ? "on (pinned in RAM)" : "off (Ollama unloads after 5 min; +7-10s on a cold call)")")
        } else {
            print("  · llm               disabled — no free-form spoken commands")
        }

        // Environment
        let mic = Permissions.microphone
        print("  \(mic == .granted ? "✓" : "✗") microphone        \(mic.label)")
        if mic != .granted { ok = false }

        if let device = AVCaptureDevice.default(for: .audio) {
            print("  ✓ input device      \(device.localizedName)")
        } else {
            print("  ✗ input device      none found")
            ok = false
        }

        // Accessibility deliberately isn't tested here.
        //
        // Asking `AXIsProcessTrustedWithOptions` from this command answers a
        // different question than it appears to. TCC attributes the check to the
        // *responsible* process, and for a binary exec'd from a shell that is the
        // terminal, not ParrotFlow. Measured on a Mac where the app had the grant
        // and was using it: launched by macOS it reported Granted, the same
        // bundle run from a terminal reported Not granted. A check that says no
        // when the answer is yes is worse than no check, so it reports where the
        // real answer lives instead — the app tests it at launch and logs it.
        if transcription.insertMode == .paste || !transcription.activationPhrase.isEmpty {
            print("  · accessibility     needed, but not checkable from a terminal")
            print("      macOS credits this check to the shell, not to ParrotFlow.")
            print("      The app records the true value each time it starts:")
            print("      grep 'launched —' \(Log.fileURL.path) | tail -1")
        }

        return ok ? 0 : 1
    }

    /// Digs the real cause out of the wrappers. Yams reports both its own parse
    /// failures and our validation errors as `DecodingError.dataCorrupted`, and
    /// the default `localizedDescription` for either is useless ("Yams.YamlError
    /// error 2"). `YamlError`'s own description carries the line and column.
    static func describe(_ error: Error) -> String {
        switch error {
        case let configError as ConfigError:
            return configError.localizedDescription

        case let yamlError as YamlError:
            return String(describing: yamlError)
                .trimmingCharacters(in: .whitespacesAndNewlines)

        case let decodingError as DecodingError:
            switch decodingError {
            case .dataCorrupted(let context):
                if let underlying = context.underlyingError {
                    return describe(underlying)
                }
                return context.debugDescription
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "\(path.isEmpty ? "" : path + ": ")\(context.debugDescription)"
            case .keyNotFound(let key, _):
                return "missing key \"\(key.stringValue)\""
            @unknown default:
                return decodingError.localizedDescription
            }

        default:
            return error.localizedDescription
        }
    }
}
