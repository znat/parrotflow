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

    /// The numbered list items in a prompt: the openings the explain prompt
    /// offers, picked by number so lines in a row start differently.
    static func openings(in text: String) -> Int {
        text.split(separator: "\n").filter { $0.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil }.count
    }

    /// A random opening other than `last`, or nil when there are none.
    static func opening(count: Int, after last: Int?) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 1 }
        return (1...count).filter { $0 != last }.randomElement()
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

    /// Why an override that is there is not used, or nil.
    var overrideProblem: String? {
        guard FileManager.default.fileExists(atPath: override.path) else { return nil }
        guard let text = try? String(contentsOf: override, encoding: .utf8) else {
            return "cannot be read as UTF-8 text"
        }
        return Self.instructions(in: text) == nil ? "is empty" : nil
    }

    static func instructions(at url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(instructions(in:))
    }

    /// The text without its leading `<!-- -->` note, trimmed. Nil when
    /// nothing is left.
    static func instructions(in file: String) -> String? {
        var text = file.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<!--"), let end = text.range(of: "-->") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}
