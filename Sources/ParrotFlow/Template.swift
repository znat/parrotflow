import Foundation

/// Puts scope values into a prompt, and takes out the parts there is nothing to
/// put in.
///
/// A prompt names a variable the way a condition does — `{{context.text}}`,
/// `{{numbers.count}}`, `{{language}}` — so there is one set of names to learn
/// rather than one for `when:` and another for the prompt body. Anything a stage
/// published is reachable, as long as that stage ran earlier in the pipeline.
///
/// ## Why a missing value removes the paragraph around it
///
/// Most variables are absent most of the time. `context` only reads terminals,
/// so in Slack or Mail there is no screen, and a stage that declines still
/// publishes its keys — emptied. Substituting that empty string leaves:
///
///     This is what is on the user's screen right now:
///
/// which is worse than saying nothing. It tells a model there is a screen and
/// then shows it none, and a small model asked to use something that is not
/// there will invent it. So the paragraph goes too.
///
/// The unit is the paragraph rather than the line because that is the unit a
/// prompt is written in: a heading and its content are one thought, and dropping
/// only the line with the placeholder would strip the value and keep the promise.
///
/// One placeholder with nothing behind it takes the whole paragraph, even if
/// another in the same paragraph resolved. A paragraph is a single claim; half
/// of it is not a smaller claim, it is a wrong one.
enum Template {

    /// Fill `template` from `scope`, dropping what cannot be filled.
    static func fill(_ template: String, from scope: Scope) -> String {
        let lines = template.components(separatedBy: "\n")
        var out: [String] = []
        var index = 0

        while index < lines.count {
            guard !isBlank(lines[index]) else {
                out.append(lines[index])
                index += 1
                continue
            }

            var end = index
            while end < lines.count, !isBlank(lines[end]) { end += 1 }

            if let filled = fill(paragraph: Array(lines[index..<end]), from: scope) {
                out.append(contentsOf: filled)
                index = end
                continue
            }

            // Dropped. The blank line that separated this paragraph from the
            // next goes with it, or two paragraphs become one when the text
            // between them disappears.
            index = end < lines.count ? end + 1 : end
        }

        while let last = out.last, isBlank(last) { out.removeLast() }
        while let first = out.first, isBlank(first) { out.removeFirst() }
        let result = out.joined(separator: "\n")

        // A prompt made of nothing but placeholders would vanish entirely, and
        // an empty system message is not a smaller instruction — it is no
        // instruction, which is the one outcome worse than a dangling heading.
        // So in that case the paragraphs stay and the gaps are simply empty.
        if result.isEmpty, !isBlank(template) {
            return substituting(template, from: scope)
        }
        return result
    }

    /// The filled paragraph, or nil if a placeholder in it had nothing behind it.
    private static func fill(paragraph: [String], from scope: Scope) -> [String]? {
        var filled: [String] = []
        for line in paragraph {
            var result = ""
            var cursor = line.startIndex
            for found in placeholders(in: line) {
                guard let value = value(for: found.path, in: scope) else { return nil }
                result += line[cursor..<found.range.lowerBound] + value
                cursor = found.range.upperBound
            }
            result += line[cursor...]
            filled.append(result)
        }
        return filled
    }

    /// Every placeholder in one line, in order.
    ///
    /// Scanned rather than matched with a regular expression because the thing
    /// being looked for is two literal pairs of braces, and a pattern for that
    /// is four escapes deep before it says anything.
    static func placeholders(in line: String) -> [(range: Range<String.Index>, path: String)] {
        var found: [(Range<String.Index>, String)] = []
        var cursor = line.startIndex
        while let open = line.range(of: "{{", range: cursor..<line.endIndex) {
            guard let close = line.range(of: "}}", range: open.upperBound..<line.endIndex) else {
                break
            }
            let path = line[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            found.append((open.lowerBound..<close.upperBound, path))
            cursor = close.upperBound
        }
        return found
    }

    /// What goes in place of a name, or nil when there is nothing to put there.
    ///
    /// A path the scope has never heard of and a path holding an empty string
    /// are the same answer on purpose. A stage that declined publishes its keys
    /// emptied rather than absent — see `readContext` — so a prompt that treated
    /// the two differently would behave one way in a terminal with a blank
    /// screen and another way in Slack, for no reason a reader could see.
    private static func value(for path: String, in scope: Scope) -> String? {
        guard let value = scope[path] else { return nil }
        let plain = value.plain
        return plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : plain
    }

    /// Every placeholder replaced by whatever is behind it, empty included, and
    /// no paragraph dropped. Only the all-placeholder fallback uses this.
    private static func substituting(_ template: String, from scope: Scope) -> String {
        template.components(separatedBy: "\n").map { line -> String in
            var result = ""
            var cursor = line.startIndex
            for found in placeholders(in: line) {
                result += line[cursor..<found.range.lowerBound]
                    + (value(for: found.path, in: scope) ?? "")
                cursor = found.range.upperBound
            }
            return result + line[cursor...]
        }.joined(separator: "\n")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
