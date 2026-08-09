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

    // MARK: - Recording a rendering against its term

    /// Records that `term` came out as `heard`, and returns how many times that
    /// has now been seen.
    ///
    /// Written into `vocabulary.yaml` rather than `config.yaml`, which is where
    /// a correction used to land. Three reasons, and none of them changes what
    /// the app does with the rule: `Config.vocabularyRules` turns a rendering
    /// into the same exact replacement `transcription.replacements` carried, so
    /// the correction still fires. `vocabulary.yaml` is the file that is written
    /// by the app and read by a person, which is what a learnt entry is. And it
    /// is the only one `--forget` can reach — a correction written to
    /// `config.yaml` could never be taken back.
    ///
    /// Always as a `pronunciations:` entry, even when the rendering is already
    /// in a legacy `heard:` list. That is the shape with `seen:` and `from:` on
    /// it, `Config.Term` reads both keys as one list and prefers the entry that
    /// knows something about itself, so this upgrades a bare spelling in place
    /// rather than duplicating it.
    @discardableResult
    static func addPronunciation(term: String, heard: String) throws -> Int {
        let url = ConfigStore.vocabularyURL
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let (updated, seen) = adding(pronunciation: heard, to: term, in: original)
        if updated != original {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
        return seen
    }

    /// The file with one rendering recorded against its term, and the count it
    /// now stands at.
    static func adding(
        pronunciation heard: String, to term: String, in yaml: String
    ) -> (String, Int) {
        var lines = yaml.components(separatedBy: "\n")
        guard let start = index(ofTerm: term, in: lines) else { return (yaml, 0) }
        let termIndent = indentation(of: lines[start])
        let bodyIndent = termIndent + "  "

        // Whatever the term's value is today, in block form, so a
        // `pronunciations:` list can be appended under it. A legacy floor and a
        // legacy `heard:` list both survive this — they are still read.
        var end = start
        let head = lines[start]
        let colon = head.firstIndex(of: ":")!
        let inline = String(head[head.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if !inline.isEmpty && !inline.hasPrefix("#") {
            let closes = closingFlow(in: lines, from: start, deeperThan: termIndent.count)
            let value = lines[start...closes].joined(separator: " ")
            let body = String(value[value.index(after: value.firstIndex(of: ":")!)...])
                .trimmingCharacters(in: .whitespaces)
            // A bare list is the old `heard:`; a bare number is the old `floor:`.
            let key = body.hasPrefix("[") ? "heard" : "floor"
            lines.replaceSubrange(start...closes, with: [
                "\(termIndent)\(quoted(term)):",
                "\(bodyIndent)\(key): \(body)",
            ])
            end = start + 1
        } else {
            end = endOfTermBlock(in: lines, from: start, deeperThan: termIndent.count)
        }

        // An existing `pronunciations:` block, and this rendering inside it.
        var listIndex: Int?
        var cursor = start + 1
        while cursor <= end, cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pronunciations:") { listIndex = cursor; break }
            cursor += 1
        }

        guard let listAt = listIndex else {
            lines.insert(contentsOf: [
                "\(bodyIndent)pronunciations:",
                "\(bodyIndent)  - heard: \(quoted(heard))",
                "\(bodyIndent)    seen: 1",
                "\(bodyIndent)    from: correction",
            ], at: end + 1)
            return (lines.joined(separator: "\n"), 1)
        }

        // `pronunciations: [a, b]` is legal YAML and nothing writes it, but a
        // person may have. Left alone rather than rewritten: appending a block
        // entry under a flow sequence would not parse.
        let listIndent = indentation(of: lines[listAt])
        if lines[listAt].trimmingCharacters(in: .whitespaces).dropFirst("pronunciations:".count)
            .trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            return (yaml, 0)
        }

        let listEnd = endOfTermBlock(in: lines, from: listAt, deeperThan: listIndent.count)
        let entryIndent = listIndent + "  "
        if let found = entry(named: heard, in: lines, from: listAt + 1, through: listEnd) {
            let seen = bump(seen: found, in: &lines, through: listEnd, indent: entryIndent)
            return (lines.joined(separator: "\n"), seen)
        }

        lines.insert(contentsOf: [
            "\(entryIndent)- heard: \(quoted(heard))",
            "\(entryIndent)  seen: 1",
            "\(entryIndent)  from: correction",
        ], at: listEnd + 1)
        return (lines.joined(separator: "\n"), 1)
    }

    /// Removes one rendering from a term's `pronunciations:`. True if it went.
    ///
    /// Only the block shape, which is the only shape this writes. A rendering
    /// in a legacy `heard:` list is left where it is — that entry records
    /// nothing about its own provenance, so nothing here knows enough about it
    /// to delete it.
    @discardableResult
    static func dropPronunciation(term: String, heard: String) throws -> Bool {
        let url = ConfigStore.vocabularyURL
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = original.components(separatedBy: "\n")
        guard let start = index(ofTerm: term, in: lines) else { return false }
        let termIndent = indentation(of: lines[start]).count
        let end = endOfTermBlock(in: lines, from: start, deeperThan: termIndent)

        var listAt: Int?
        for cursor in (start + 1)...max(start + 1, end) where cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("pronunciations:") {
                listAt = cursor
                break
            }
        }
        guard let listAt else { return false }
        let listEnd = endOfTermBlock(
            in: lines, from: listAt, deeperThan: indentation(of: lines[listAt]).count
        )
        guard let found = entry(named: heard, in: lines, from: listAt + 1, through: listEnd) else {
            return false
        }
        let last = endOfEntry(in: lines, from: found, through: listEnd)
        lines.removeSubrange(found...last)
        // A `pronunciations:` key with nothing under it decodes as null, not as
        // an empty list, so it goes too.
        if endOfTermBlock(
            in: lines, from: listAt, deeperThan: indentation(of: lines[listAt]).count
        ) == listAt {
            lines.remove(at: listAt)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// The line of `- heard: <name>` inside a `pronunciations:` block.
    private static func entry(
        named heard: String, in lines: [String], from: Int, through last: Int
    ) -> Int? {
        for cursor in from...max(from, last) where cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { continue }
            let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            // `- heard: Versal` and the bare `- Versal` a person may have typed.
            let spelling: String
            if body.hasPrefix("heard:") {
                spelling = unquoted(String(body.dropFirst("heard:".count)))
            } else if !body.contains(":") {
                spelling = unquoted(body)
            } else {
                continue
            }
            if spelling.caseInsensitiveCompare(heard) == .orderedSame { return cursor }
        }
        return nil
    }

    /// The last line of the `- heard:` entry that starts at `from`.
    private static func endOfEntry(in lines: [String], from: Int, through last: Int) -> Int {
        var cursor = from + 1
        var end = from
        while cursor <= last, cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-") { break }
            if !trimmed.isEmpty { end = cursor }
            cursor += 1
        }
        return end
    }

    /// Adds one to an entry's `seen:`, writing the key if it had none.
    private static func bump(
        seen entry: Int, in lines: inout [String], through last: Int, indent: String
    ) -> Int {
        let end = endOfEntry(in: lines, from: entry, through: last)
        for cursor in entry...end {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("-")
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            guard body.hasPrefix("seen:") else { continue }
            let was = Int(String(body.dropFirst("seen:".count))
                .trimmingCharacters(in: .whitespaces)) ?? 0
            lines[cursor] = "\(indentation(of: lines[cursor]))seen: \(was + 1)"
            return was + 1
        }
        // No `seen:` at all: an entry written before the key existed. It has
        // been seen at least once before now, hence 2 and not 1.
        lines.insert("\(indent)  seen: 2", at: end + 1)
        return 2
    }

    /// The line a term's key sits on, inside `terms:`.
    private static func index(ofTerm term: String, in lines: [String]) -> Int? {
        guard let termsIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("terms:")
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }) else { return nil }
        let outer = indentation(of: lines[termsIndex]).count
        var index = termsIndex + 1
        var at: Int?
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
            if indentation(of: line).count <= outer { break }
            // Only a key at the term level, so a `heard:` inside another term's
            // body cannot be mistaken for a term called `heard`.
            if indentation(of: line).count == outer + 2, let colon = trimmed.firstIndex(of: ":"),
               unquoted(String(trimmed[trimmed.startIndex..<colon]))
                   .caseInsensitiveCompare(term) == .orderedSame {
                at = index
                break
            }
            index += 1
        }
        return at
    }

    /// The last line indented deeper than `indent`, starting from `start`.
    private static func endOfTermBlock(in lines: [String], from start: Int, deeperThan indent: Int) -> Int {
        var index = start + 1
        var last = start
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if indentation(of: line).count <= indent { break }
            last = index
            index += 1
        }
        return last
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
