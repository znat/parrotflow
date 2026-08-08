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

    /// Records that `heard` should be written as `corrected`.
    static func addReplacement(heard: String, corrected: String) throws {
        let url = ConfigStore.fileURL
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = try insert(heard: heard, corrected: corrected, into: original)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Splices the mishearing into the list under its target spelling, adding
    /// the target if it is new.
    ///
    /// Text-level rather than decode-edit-encode: round-tripping through Yams
    /// would strip every comment in the file, and the comments are most of what
    /// makes that config readable.
    static func insert(heard: String, corrected: String, into yaml: String) throws -> String {
        var lines = yaml.components(separatedBy: "\n")

        guard let transcriptionIndex = lines.firstIndex(where: {
            $0.hasPrefix("transcription:")
        }) else {
            throw WriteError.noTranscriptionSection
        }

        // Find `replacements:` inside the transcription block, which ends at
        // the first non-indented, non-blank line.
        var replacementsIndex: Int?
        var index = transcriptionIndex + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !trimmed.isEmpty { break }
            if trimmed.hasPrefix("replacements:") { replacementsIndex = index; break }
            index += 1
        }

        guard let start = replacementsIndex else {
            let insertAt = endOfBlock(in: lines, from: transcriptionIndex)
            lines.insert(contentsOf: [
                "  replacements:",
                "    \(quoted(corrected)): [\(quoted(heard))]",
            ], at: insertAt)
            return lines.joined(separator: "\n")
        }

        let keyIndent = indentation(of: lines[start])
        let entryIndent = keyIndent + "  "

        // `replacements: {}` has to become a block mapping first.
        if lines[start].trimmingCharacters(in: .whitespaces).hasSuffix("{}") {
            lines[start] = "\(keyIndent)replacements:"
            lines.insert("\(entryIndent)\(quoted(corrected)): [\(quoted(heard))]", at: start + 1)
            return lines.joined(separator: "\n")
        }

        // Look for the target, and append to its list if it is already there.
        var lastEntry = start
        var cursor = start + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            guard indentation(of: line).count > keyIndent.count else { break }

            if !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") {
                let existing = unquoted(String(trimmed[trimmed.startIndex..<colon]))
                if existing.caseInsensitiveCompare(corrected) == .orderedSame {
                    let sources = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    // Already listed: nothing to add.
                    if sources.contains(heard) { return yaml }
                    if let close = line.lastIndex(of: "]") {
                        let separator = sources == "[]" ? "" : ", "
                        lines[cursor] = String(line[line.startIndex..<close])
                            + separator + quoted(heard) + "]"
                        return lines.joined(separator: "\n")
                    }
                }
                lastEntry = cursor
            }
            cursor += 1
        }

        lines.insert(
            "\(entryIndent)\(quoted(corrected)): [\(quoted(heard))]",
            at: lastEntry + 1
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - Forgetting a term's pronunciations

    /// Removes every rendering recorded for `term` from `vocabulary.yaml`.
    ///
    /// The term itself stays. Forgetting is about the learnt half — the
    /// spellings and the audio that piled up behind a name — and a person who
    /// wanted the name gone would delete the name.
    ///
    /// Text-level, for the same reason `insert` is: this file carries a long
    /// header explaining what its numbers mean, and a round trip through Yams
    /// would throw all of it away.
    static func forgetPronunciations(of term: String) throws -> Int {
        let url = ConfigStore.vocabularyURL
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let (updated, removed) = dropping(pronunciationsOf: term, from: original)
        if removed > 0 {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
        return removed
    }

    /// The file with one term's renderings taken out, and how many went.
    ///
    /// Three shapes have to be handled, because the file has been written three
    /// ways: the shorthand `Praisy: [Prissy, Pressy]`, the old
    /// `heard: [Prissy, Pressy]` — which spans lines in the file this was
    /// written against — and a `pronunciations:` block of `- heard:` entries.
    static func dropping(
        pronunciationsOf term: String, from yaml: String
    ) -> (String, Int) {
        var lines = yaml.components(separatedBy: "\n")
        guard let termsIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("terms:")
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }) else { return (yaml, 0) }
        let termIndent = indentation(of: lines[termsIndex]).count

        // The term's own line, inside `terms:`.
        var at: Int?
        var index = termsIndex + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
            if indentation(of: line).count <= termIndent { break }
            if let colon = trimmed.firstIndex(of: ":"),
               unquoted(String(trimmed[trimmed.startIndex..<colon]))
                   .caseInsensitiveCompare(term) == .orderedSame {
                at = index
                break
            }
            index += 1
        }
        guard let start = at else { return (yaml, 0) }

        var removed = 0
        // `Praisy: [Prissy, Pressy]` — the whole value is the list.
        let head = lines[start]
        if let colon = head.firstIndex(of: ":"),
           head[head.index(after: colon)...].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let end = closingFlow(in: lines, from: start, deeperThan: termIndent)
            removed = count(inFlow: lines[start...end].joined(separator: " "))
            lines.replaceSubrange(start...end, with: [String(head[head.startIndex...colon])])
            return (lines.joined(separator: "\n"), removed)
        }

        // A block body: find `heard:` or `pronunciations:` inside it.
        let bodyIndent = indentation(of: lines[start]).count
        var cursor = start + 1
        var cut: [Range<Int>] = []
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            if indentation(of: line).count <= bodyIndent { break }
            if trimmed.hasPrefix("heard:") || trimmed.hasPrefix("pronunciations:") {
                let keyIndent = indentation(of: line).count
                var end = closingFlow(in: lines, from: cursor, deeperThan: keyIndent)
                removed += count(inFlow: lines[cursor...end].joined(separator: " "))
                // A block sequence continues under the key rather than on it.
                var below = end + 1
                while below < lines.count {
                    let next = lines[below]
                    let bare = next.trimmingCharacters(in: .whitespaces)
                    if bare.isEmpty { below += 1; continue }
                    if indentation(of: next).count <= keyIndent { break }
                    if bare.hasPrefix("- ") || bare.hasPrefix("-\t") || bare == "-" { removed += 1 }
                    end = below
                    below += 1
                }
                cut.append(cursor..<(end + 1))
                cursor = end + 1
                continue
            }
            cursor += 1
        }
        for range in cut.reversed() { lines.removeSubrange(range) }
        return (lines.joined(separator: "\n"), removed)
    }

    /// The last line of a flow sequence that starts on `from`. The live file
    /// wraps one over two lines, and cutting only the first leaves the tail
    /// behind as invalid YAML.
    ///
    /// Bounded by indentation as well as by the brackets. An unclosed `[` is a
    /// file that would not have loaded, and a scan that runs to the end of it
    /// would delete everything after the mistake rather than nothing.
    private static func closingFlow(in lines: [String], from: Int, deeperThan indent: Int) -> Int {
        var depth = 0
        var index = from
        while index < lines.count {
            if index > from, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
               indentation(of: lines[index]).count <= indent {
                return index - 1
            }
            for character in lines[index] {
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1 }
            }
            if depth <= 0 { return index }
            index += 1
        }
        return lines.count - 1
    }

    /// How many entries a flow sequence holds. Only used to report a number, so
    /// an empty list and a missing one both count as nothing.
    private static func count(inFlow text: String) -> Int {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"),
              open < close else { return 0 }
        let inside = text[text.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return inside.count
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
