import Foundation

/// The voice's three model prompts. The instructions ship in
/// `built-in/voice/<name>.md`; a file with the same name in `<config>/voice/`
/// replaces them. `format` is the app's and always follows them.
enum VoicePrompt: String, CaseIterable {
    case rewrite, explain, reminder

    enum Source: Equatable {
        case builtIn
        case override(URL)

        var shown: String {
            switch self {
            case .builtIn: return "built-in"
            case .override(let url): return ClaudeHooksCommand.shown(url)
            }
        }
    }

    /// The reply shape the code reads: `parseSpoken` and `taskLabel` for the
    /// rewrite, the whole reply as the line for the other two.
    var format: String {
        switch self {
        case .rewrite:
            return """
                Return JSON: {"opener": "...", "say": "...", "tone": "...", "task": "..."}

                task: two or three lowercase words, in the language of "Language", that name \
                what the developer is working on, from the request. No punctuation. Like: fixing the glow.
                """
        case .explain: return "Output only the sentence."
        case .reminder: return "Output only the reminder."
        }
    }

    static var directory: URL {
        ConfigStore.directory.appendingPathComponent("voice", isDirectory: true)
    }

    /// The reference copies, refreshed on every launch like `transforms/built-in/`.
    static var installedDirectory: URL {
        directory.appendingPathComponent("built-in", isDirectory: true)
    }

    static var builtInDirectory: URL {
        ConfigStore.builtInDirectory.appendingPathComponent("voice", isDirectory: true)
    }

    var override: URL { Self.directory.appendingPathComponent(rawValue + ".md") }
    var builtIn: URL { Self.builtInDirectory.appendingPathComponent(rawValue + ".md") }

    /// Read on every call, so an edit applies to the next line. An empty
    /// override falls back to the built-in. Nil when the built-in file is
    /// missing too.
    var current: (text: String, source: Source)? {
        if let text = Self.instructions(at: override) {
            return (text + "\n\n" + format, .override(override))
        }
        return Self.instructions(at: builtIn).map { ($0 + "\n\n" + format, .builtIn) }
    }

    /// An override that is there and has no text.
    var overrideIsEmpty: Bool {
        FileManager.default.fileExists(atPath: override.path) && Self.instructions(at: override) == nil
    }

    /// The file without its leading `<!-- -->` note, trimmed. Nil when it is
    /// missing or has no text.
    static func instructions(at url: URL) -> String? {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<!--"), let end = text.range(of: "-->") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}
