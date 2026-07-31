import Foundation

/// Runs a prompt over some text.
///
/// The prompt's `content` is the standing rule and goes in as the system
/// message; what the speaker actually said goes in as the user message beside
/// the text. That split is the whole reason a prompt can be reused — "format
/// those dates ISO" and "format those dates with slashes" are one rule and two
/// instructions, and a design that folded them together would need an entry per
/// format.
enum PromptRunner {

    /// Ceiling on the answer, derived from the input.
    ///
    /// A transform mostly returns the text it was given, so the input length is
    /// the right basis — a fixed cap either truncates long passages or lets a
    /// short one ramble. Doubled and floored so a rewrite that legitimately
    /// grows has room, and so the shortest input still gets a usable budget.
    ///
    /// Roughly four characters to a token, which is close enough for a ceiling
    /// nobody should be hitting.
    static func tokenBudget(for text: String) -> Int {
        max(256, (text.count / 4) * 2)
    }

    static func compose(
        prompt: Config.Prompt, instruction: String, text: String
    ) -> (system: String, user: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        // Asked for inline, the instruction goes where the prompt puts it and
        // nowhere else — repeating it in the user message would have the model
        // weighing two copies of the same sentence.
        if prompt.wantsInstructionInline {
            return (
                system: prompt.content.replacingOccurrences(
                    of: Config.Prompt.instructionPlaceholder, with: instruction
                ),
                user: text
            )
        }

        guard !instruction.isEmpty else { return (prompt.content, text) }
        return (prompt.content, "instruction: \(instruction)\n\ntext:\n\(text)")
    }

    static func run(
        prompt: Config.Prompt,
        instruction: String,
        text: String,
        config: LocalLLM.Config
    ) async throws -> String {
        let composed = compose(prompt: prompt, instruction: instruction, text: text)
        let raw = try await LocalLLM.complete(
            system: composed.system,
            user: composed.user,
            json: false,
            maxTokens: tokenBudget(for: text),
            config: config
        )
        return clean(raw)
    }

    /// Strips the wrapping a model adds despite being told not to.
    ///
    /// Only ever removes — a fence, a "Here is the corrected text:" opener,
    /// surrounding quotes. Anything that would edit the text itself belongs to
    /// the prompt, because a cleanup step that rewrites is indistinguishable
    /// from the model doing it and impossible to measure separately.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: .newlines)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // "Here is the corrected text:" and friends, but only when the label
        // sits on its own line — a colon mid-sentence is the speaker's.
        if let newline = text.firstIndex(of: "\n") {
            let first = text[text.startIndex..<newline].trimmingCharacters(in: .whitespaces)
            if first.hasSuffix(":"), first.count < 60, !first.hasPrefix("-") {
                text = String(text[text.index(after: newline)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
