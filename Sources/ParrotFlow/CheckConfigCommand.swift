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
            print("  · wake phrase       \"\(transcription.correctionPhrase)\"")
            print("  · rewrite line      \(transcription.rewriteLine ? "on" : "off (terminals can't be edited without it)")")
        }
        if transcription.enabled {
            if transcription.vocabulary.isEmpty {
                print("  · vocabulary        none")
            } else {
                print("  ✓ vocabulary        \(transcription.vocabulary.count) terms")
                for term in transcription.vocabulary {
                    let aliases = term.aliases.isEmpty
                        ? ""
                        : "  ← \(term.aliases.joined(separator: ", "))"
                    print("      \(term.text)\(aliases)")
                }
            }
            if !transcription.replacements.isEmpty {
                print("  ✓ replacements      \(transcription.replacements.count)")
                for (from, to) in transcription.replacements.sorted(by: { $0.key < $1.key }) {
                    print("      \(from) → \(to)")
                }
            }
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
