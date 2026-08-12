import Foundation

/// Writes what a correction taught into `vocabulary.yaml`, without disturbing
/// anything else in it.
///
/// Deliberately text-level rather than decode-edit-encode: round-tripping
/// through Yams would strip every comment in the file, and the comments are
/// most of what makes that config readable. So we find the `terms:` block and
/// splice a pronunciation into it.
enum ConfigWriter {

    // MARK: - Learning a pronunciation

    /// Records that `term` is sometimes heard as `heard`.
    ///
    /// Where the correction panel, `--learn` and the voice spelling command
    /// write — see `Config.Vocabulary`. `config.yaml`'s `transcription.
    /// replacements` stays for patterns and deletions; a name the recogniser
    /// mangled is a pronunciation, not a pattern, and belongs beside the
    /// pronunciations the acoustic pass already found on its own.
    static func addVocabularyPronunciation(term: String, heard: String) throws {
        let url = ConfigStore.vocabularyURL
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? "terms: {}\n"
        let updated = try insertVocabulary(term: term, heard: heard, into: original)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Splices the rendering into the term's `pronunciations:`, adding the
    /// term if it is new.
    ///
    /// `from: correction` is what tells this rendering apart from one
    /// `scripts/mine-pronunciations.py` found on its own — see
    /// `Config.Vocabulary.Pronunciation.Source`.
    static func insertVocabulary(term: String, heard: String, into yaml: String) throws -> String {
        var lines = yaml.components(separatedBy: "\n")
        let entry = ["      - heard: \(quoted(heard))", "        from: correction"]

        guard let termsIndex = lines.firstIndex(where: { $0.hasPrefix("terms:") }) else {
            var out = lines
            if let last = out.last, !last.isEmpty { out.append("") }
            out.append("terms:")
            out.append(contentsOf: newTerm(term, entry: entry))
            return out.joined(separator: "\n")
        }

        // `terms: {}` has to become a block mapping first.
        if lines[termsIndex].trimmingCharacters(in: .whitespaces).hasSuffix("{}") {
            lines[termsIndex] = "terms:"
            lines.insert(contentsOf: newTerm(term, entry: entry), at: termsIndex + 1)
            return lines.joined(separator: "\n")
        }

        // Find the term's own line, directly under `terms:`.
        var start: Int?
        var cursor = termsIndex + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            guard line.hasPrefix(" ") else { break }
            if indentation(of: line).count == 2, !trimmed.hasPrefix("#"),
               let colon = trimmed.firstIndex(of: ":"),
               unquoted(String(trimmed[trimmed.startIndex..<colon]))
                   .caseInsensitiveCompare(term) == .orderedSame {
                start = cursor
                break
            }
            cursor += 1
        }

        guard let start else {
            // A new term: append at the end of `terms:`.
            let insertAt = endOfBlock(in: lines, from: termsIndex)
            lines.insert(contentsOf: newTerm(term, entry: entry), at: insertAt)
            return lines.joined(separator: "\n")
        }

        let head = lines[start]
        guard let colon = head.firstIndex(of: ":") else { return yaml }
        let value = String(head[head.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        // Shorthand list: `Term: [a, b]`, possibly wrapped over two lines.
        if value.hasPrefix("[") {
            let end = closingFlow(in: lines, from: start, deeperThan: 2)
            let sources = lines[start...end].joined(separator: " ")
            if sources.contains(heard) { return yaml }
            guard let close = lines[end].lastIndex(of: "]") else { return yaml }
            let before = String(lines[end][lines[end].startIndex..<close])
            let separator = before.trimmingCharacters(in: .whitespaces).hasSuffix("[") ? "" : ", "
            lines[end] = before + separator + quoted(heard) + "]"
            return lines.joined(separator: "\n")
        }

        // A block already — `floor:`, `pronunciations:`, or both — or a bare
        // (`Term:`) or legacy-floor (`Term: 0.85`) term with neither yet.
        let bodyIndent = 4
        var blockEnd = start
        var pronunciationsLine: Int?
        cursor = start + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            guard indentation(of: line).count >= bodyIndent else { break }
            if indentation(of: line).count == bodyIndent, trimmed.hasPrefix("pronunciations:") {
                pronunciationsLine = cursor
            }
            blockEnd = cursor
            cursor += 1
        }

        if let pronunciationsStart = pronunciationsLine {
            var listEnd = pronunciationsStart
            var scan = pronunciationsStart + 1
            while scan < lines.count {
                let line = lines[scan]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { scan += 1; continue }
                guard indentation(of: line).count > bodyIndent else { break }
                let bare = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
                let existing = bare.hasPrefix("heard:")
                    ? unquoted(String(bare.dropFirst("heard:".count)).trimmingCharacters(in: .whitespaces))
                    : unquoted(bare)
                if existing.caseInsensitiveCompare(heard) == .orderedSame { return yaml }
                listEnd = scan
                scan += 1
            }
            lines.insert(contentsOf: entry, at: listEnd + 1)
            return lines.joined(separator: "\n")
        }

        if blockEnd > start {
            // A block with `floor:` but no `pronunciations:` yet.
            lines.insert(contentsOf: ["    pronunciations:"] + entry, at: blockEnd + 1)
            return lines.joined(separator: "\n")
        }

        // Bare, or carrying a legacy floor number that has to move under its
        // own key before anything can nest below it.
        if value.isEmpty {
            lines.insert(contentsOf: ["    pronunciations:"] + entry, at: start + 1)
        } else {
            lines[start] = "  \(quoted(term)):"
            lines.insert(
                contentsOf: ["    floor: \(value)", "    pronunciations:"] + entry, at: start + 1
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func newTerm(_ term: String, entry: [String]) -> [String] {
        ["  \(quoted(term)):", "    pronunciations:"] + entry
    }

    // MARK: - Forgetting a term's pronunciations

    /// Removes every rendering recorded for `term` from `vocabulary.yaml`.
    ///
    /// The term itself stays. Forgetting is about the learnt half — the
    /// spellings and the audio that piled up behind a name — and a person who
    /// wanted the name gone would delete the name.
    ///
    /// Text-level, for the same reason `insertVocabulary` is: this file
    /// carries a long header explaining what its numbers mean, and a round
    /// trip through Yams would throw all of it away.
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
            return text.replacingOccurrences(of: "\\\"", with: "\"")
        }
        // YAML's other quote, and it is not decoration: `'Praisy':` is a legal
        // key, so a reader that only knows double quotes fails to find the term
        // and `--forget` deletes the audio while leaving the pronunciations
        // running. A single-quoted scalar escapes its own quote by doubling it,
        // and has no backslash escapes at all.
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            text = String(text.dropFirst().dropLast())
            return text.replacingOccurrences(of: "''", with: "'")
        }
        return text
    }
}
