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
            print("  · numbers           \(transcription.numbers ? "written as digits" : "left as words")")
            let languages = transcription.languages.joined(separator: ", ")
            print("  · languages         \(languages)"
                + (transcription.languages.count > 1
                   ? " (detected per transcript, picks the prompt)"
                   : " (no detection; always the \(languages) prompt)"))
        }
        if transcription.enabled {
            if !transcription.replacements.isEmpty {
                print("  · fuzzy matching    \(transcription.fuzzyMatching ? "on" : "off")")
                let total = transcription.rules.count
                print("  ✓ replacements      \(total) across \(transcription.replacements.count) entries")
                for (target, sources) in transcription.replacements.sorted(by: { $0.key < $1.key }) {
                    let name = target.isEmpty ? "(removed)" : target
                    print("      \(name) ← \(sources.sorted().joined(separator: ", "))")
                }
                let bad = transcription.rules.filter {
                    $0.isRegex && (try? NSRegularExpression(pattern: $0.pattern)) == nil
                }
                for rule in bad {
                    print("  ✗ not a valid pattern: \(rule.source)")
                    ok = false
                }
            }
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
