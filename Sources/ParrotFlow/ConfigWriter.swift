import Foundation

/// Adds a replacement rule to config.yaml without disturbing anything else.
///
/// Deliberately text-level rather than decode-edit-encode: round-tripping
/// through Yams would strip every comment in the file, and the comments are
/// most of what makes that config readable. So we find the `replacements:`
/// block and splice one line into it.
enum ConfigWriter {

    enum WriteError: LocalizedError {
        case noTranscriptionSection

        var errorDescription: String? {
            switch self {
            case .noTranscriptionSection:
                return "config.yaml has no `transcription:` section to add the rule to."
            }
        }
    }

    /// Inserts or updates `heard: corrected` under `transcription.replacements`.
    static func addReplacement(heard: String, corrected: String) throws {
        let url = ConfigStore.fileURL
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = try insert(heard: heard, corrected: corrected, into: original)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Split out from file handling so it can be reasoned about (and tested)
    /// on its own.
    static func insert(heard: String, corrected: String, into yaml: String) throws -> String {
        var lines = yaml.components(separatedBy: "\n")

        guard let transcriptionIndex = lines.firstIndex(where: {
            $0.hasPrefix("transcription:")
        }) else {
            throw WriteError.noTranscriptionSection
        }

        let entry = "\(quoted(heard)): \(quoted(corrected))"

        // Find `replacements:` inside the transcription block. The block ends at
        // the first non-indented, non-blank line.
        var replacementsIndex: Int?
        var index = transcriptionIndex + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !trimmed.isEmpty { break }
            if trimmed.hasPrefix("replacements:") {
                replacementsIndex = index
                break
            }
            index += 1
        }

        guard let start = replacementsIndex else {
            // No replacements key: add one at the end of the transcription block.
            let insertAt = endOfBlock(in: lines, from: transcriptionIndex)
            lines.insert(contentsOf: ["  replacements:", "    \(entry)"], at: insertAt)
            return lines.joined(separator: "\n")
        }

        let keyIndent = indentation(of: lines[start])
        let entryIndent = keyIndent + "  "

        // `replacements: {}` — an empty flow mapping has to become a block
        // mapping before anything can be added to it.
        if lines[start].trimmingCharacters(in: .whitespaces).hasSuffix("{}") {
            lines[start] = "\(keyIndent)replacements:"
            lines.insert("\(entryIndent)\(entry)", at: start + 1)
            return lines.joined(separator: "\n")
        }

        // Walk the existing entries: replace the key if it's already mapped,
        // otherwise remember where the block ends.
        var lastEntry = start
        var cursor = start + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            guard indentation(of: line).count > keyIndent.count else { break }

            if !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") {
                let existing = unquoted(String(trimmed[trimmed.startIndex..<colon]))
                if existing.caseInsensitiveCompare(heard) == .orderedSame {
                    lines[cursor] = "\(entryIndent)\(entry)"
                    return lines.joined(separator: "\n")
                }
                lastEntry = cursor
            }
            cursor += 1
        }

        lines.insert("\(entryIndent)\(entry)", at: lastEntry + 1)
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func endOfBlock(in lines: [String], from start: Int) -> Int {
        var index = start + 1
        var lastContent = start
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !trimmed.isEmpty { break }
            if !trimmed.isEmpty { lastContent = index }
            index += 1
        }
        return lastContent + 1
    }

    private static func indentation(of line: String) -> String {
        String(line.prefix(while: { $0 == " " }))
    }

    /// Quote anything that isn't a plain word, so punctuation in a misheard
    /// phrase can't produce invalid YAML.
    private static func quoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        let isPlain = !value.isEmpty
            && value.unicodeScalars.allSatisfy { safe.contains($0) }
            && value.first != " "
            && value.last != " "
        if isPlain { return value }

        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func unquoted(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
            text = text.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return text
    }
}
