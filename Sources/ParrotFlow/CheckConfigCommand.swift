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
        if config.hotkey.mode == .pushToTalk {
            let tail = config.hotkey.releaseTailSeconds
            print("  · release tail      \(tail > 0 ? "\(tail)s after the key comes up" : "off — stops on the release")")
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
            let listed = transcription.activationPhrases
                .map { "\"\($0)\"" }.joined(separator: ", ")
            print("  · wake phrase       \(listed.isEmpty ? "none — spoken commands are off" : listed)")
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
                        if let transform = step.transform { described += " \(transform)" }
                        if let when = step.when { described += " when \(when)" }
                        if let unless = step.unless { described += " unless \(unless)" }
                        if let app = step.app { described += " in \(app)" }
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
        // Said, not complained about. These are true of a config that works —
        // a ✗ here used to fail the whole command over a `command:` transform
        // doing exactly what it was written to do.
        for notice in config.notices() {
            print("  · \(notice)")
        }
        if !transcription.retired.isEmpty {
            print("      pipelines:")
            print("        default: [\(Pipeline.everything.stages.map(\.name).joined(separator: ", "))]")
        }

        // Where each body actually came from.
        //
        // A file present both in the folder and at the old location beside
        // config.yaml is otherwise invisible, and "which one is running" is the
        // first question when a change you made had no effect. Printed as the
        // resolved absolute path for that reason: what the config says is
        // `slack_mentions.py`, and that is exactly the string that cannot
        // answer it.
        if !config.transforms.isEmpty {
            print("  · transforms        \(config.transforms.count) defined")
            let width = config.transforms.map(\.name.count).max() ?? 0
            for transform in config.transforms {
                let name = transform.name.padding(
                    toLength: max(width, 1), withPad: " ", startingAt: 0
                )
                print("      \(name)  \(kind(of: transform))  \(bodyPath(transform))")
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
        // Not one of the capabilities above — the router reaches it by
        // answering ANY, not by picking it off the list — so it is printed
        // apart from them rather than pretending to be a catalogue entry.
        if config.freeForm {
            print("      free-form  \(FreeForm.name) — \(FreeForm.prompt.description)")
        } else {
            print("  · free_form         off — an instruction no prompt covers is refused")
        }

        // A `replace:` transform is not in the catalogue — the router reaches
        // prompts only, for now — so it would otherwise be invisible here, and
        // "I wrote it and nothing says it exists" is the wrong way to find out
        // that it runs from a pipeline and not from your voice.
        // Tables only. A `command:` is not one, and counting its rules said
        // "0 rule(s)" about a transform that has no rules to have — the line
        // read as a broken table rather than as a program. Programs are named
        // by `notices()`, which says it of every one of them, every run.
        let tables = config.transforms.filter(\.isTable)
        if !tables.isEmpty {
            print("  · replace           \(tables.count) transform(s), reachable from a pipeline"
                + " and not by voice")
            for table in tables {
                let rules = table.rules.count
                print("      table     \(table.name) — \(rules) rule(s)"
                    + (table.description.isEmpty ? "" : ", \(table.description)"))
            }
        }

        // A `display:` is the one part of a transform that is neither matched
        // against nor run: it is what the menu bar says while the stage takes
        // its second. Nothing else can show you that you wrote it, and a
        // second of silence is exactly the symptom of having forgotten to.
        let announced = config.transforms.compactMap { transform in
            transform.displayLabel.map { (transform.name, $0) }
        }
        if !announced.isEmpty {
            print("  · display           \(announced.count) transform(s) say what they are doing")
            for (name, label) in announced {
                print("      \(name) — \"\(label)\"")
            }
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

        switch config.updates.afterDays {
        case ..<0:
            print("  · updates           never checked")
        case 0:
            print("  · updates           checked daily, offered as soon as published")
        case let days:
            print("  · updates           checked daily, offered after \(days) day\(days == 1 ? "" : "s")")
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
        if transcription.insertMode == .paste || !transcription.activationPhrases.isEmpty {
            print("  · accessibility     needed, but not checkable from a terminal")
            print("      macOS credits this check to the shell, not to ParrotFlow.")
            print("      The app records the true value each time it starts:")
            print("      grep 'launched —' \(Log.fileURL.path) | tail -1")
        }

        return ok ? 0 : 1
    }

    /// Which of the three bodies this is, in one column.
    private static func kind(of transform: Config.Transform) -> String {
        switch transform.body {
        case .prompt: return "prompt "
        case .replace: return "replace"
        case .command: return "command"
        }
    }

    /// The resolved absolute path of a body, or what it is instead of a file.
    ///
    /// `on PATH` is the honest answer for `command: sed`: nothing was resolved,
    /// the shell will look it up, and printing a path this made up would be a
    /// worse lie than saying so.
    private static func bodyPath(_ transform: Config.Transform) -> String {
        if let found = transform.resolvedSource {
            return shortened(found.path) + (found.atOldLocation ? "   (old location)" : "")
        }
        if case .command(let command) = transform.body {
            return "\(command.split(separator: " ").first ?? "") — on PATH"
        }
        return "inline"
    }

    /// `$HOME` written as `~`. The paths are long, the home half is the same on
    /// every line, and the part that differs is the part being read.
    private static func shortened(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
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
