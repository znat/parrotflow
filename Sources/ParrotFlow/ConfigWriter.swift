import Foundation

/// Writes what a correction taught into `vocabulary.yaml`, without disturbing
/// anything else in it.
///
/// Deliberately text-level rather than decode-edit-encode: round-tripping
/// through Yams would strip every comment in the file, and the comments are
/// most of what makes that config readable. So we find the `terms:` block and
/// splice a pronunciation into it.
enum ConfigWriter {

    // MARK: - The microphone order

    /// Writes `audio.microphones` into `config.yaml`, in the order given.
    ///
    /// Text-level, for the reason this whole file is: `config.yaml` is mostly
    /// comments, and a round trip through Yams would return the settings
    /// without a word of what they mean.
    ///
    /// An empty list is written as `microphones: []`, not taken out. The two
    /// mean the same thing to the recorder — follow the system — and different
    /// things to the menu: the key absent is a config nobody has decided about,
    /// which is what `hasMicrophonesKey` answers and what the menu seeds on
    /// first open. `[]` is somebody deciding, and it is left alone.
    static func setMicrophones(_ names: [String]) throws {
        try ConfigStore.createIfMissing()
        let url = ConfigStore.fileURL
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = setting(microphones: names, in: original)
        guard updated != original else { return }
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Whether `config.yaml` says anything about microphones at all.
    ///
    /// A config with no such key has never been asked the question. That is the
    /// one time the menu writes a list without being told to — see
    /// `AppDelegate.microphoneMenu`.
    static func hasMicrophonesKey() -> Bool {
        guard let yaml = try? String(contentsOf: ConfigStore.fileURL, encoding: .utf8) else {
            return false
        }
        return microphonesKey(in: yaml.components(separatedBy: "\n")) != nil
    }

    /// The file with the list replaced. Split out so it can be tested without
    /// a config on disk.
    static func setting(microphones names: [String], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        // An empty list is the key and nothing under it. The recorder reads the
        // same nothing either way; what this preserves is that somebody said so.
        let keyLine = names.isEmpty ? "  microphones: []" : "  microphones:"
        let block = names.map { "    - \(quoted($0))" }

        guard let audio = lines.firstIndex(where: { $0 == "audio:" }) else {
            // No `audio:` at all — a hand-trimmed config. Appended whole, after
            // a blank line, so it does not run into whatever ends the file.
            var appended = lines
            if appended.last?.isEmpty == false { appended.append("") }
            appended.append(contentsOf: ["audio:", keyLine] + block + [""])
            return appended.joined(separator: "\n")
        }

        let end = endOfBlock(from: audio, in: lines)

        if let key = microphonesKey(in: lines, within: audio..<end) {
            lines.replaceSubrange(key..<endOfList(from: key, in: lines, within: end),
                                  with: [keyLine] + block)
            return lines.joined(separator: "\n")
        }

        // Under the last setting in the block rather than under `audio:`, so
        // the comment above the first setting keeps the setting it describes.
        var insertAt = end
        while insertAt > audio + 1, lines[insertAt - 1].isEmpty { insertAt -= 1 }
        lines.insert(contentsOf: [keyLine] + block, at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// Where the `audio:` block stops: the next line at column zero that is
    /// neither blank nor a comment. A comment between two settings belongs to
    /// the setting under it, and stopping on one would splice this list above it.
    private static func endOfBlock(from start: Int, in lines: [String]) -> Int {
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("#") { break }
            end += 1
        }
        return end
    }

    /// Everything the old list occupies: the key line and the item lines under
    /// it, including a comment or a blank line between two items. A flow list —
    /// `microphones: [a, b]` — is one line and is covered by the key line alone.
    ///
    /// A comment after the last item is left where it is. It belongs to
    /// whatever comes next, not to the list that ended above it.
    private static func endOfList(from key: Int, in lines: [String], within end: Int) -> Int {
        var last = key + 1
        var cursor = key + 1
        while cursor < end {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                cursor += 1
                last = cursor
            } else if line.isEmpty || line.hasPrefix("#") {
                cursor += 1
            } else {
                break
            }
        }
        return last
    }

    /// The `microphones:` line inside the `audio:` block, or nil if the file
    /// does not carry one. A commented-out example is not one — it is what
    /// `config.example.yaml` ships to explain the setting.
    private static func microphonesKey(
        in lines: [String], within range: Range<Int>? = nil
    ) -> Int? {
        let range = range ?? {
            guard let audio = lines.firstIndex(where: { $0 == "audio:" }) else { return 0..<0 }
            return audio..<endOfBlock(from: audio, in: lines)
        }()
        return lines[range].firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("microphones:")
        }
    }

    // MARK: - Learning a pronunciation

    /// Records that `term` is sometimes heard as `heard`.
    ///
    /// Where the correction panel, `--learn` and the voice spelling command
    /// write — see `Config.Vocabulary`. `config.yaml`'s `transcription.
    /// replacements` stays for patterns and deletions; a name the recogniser
    /// mangled is a pronunciation, not a pattern, and belongs beside the
    /// pronunciations the acoustic pass already found on its own.
    static func addVocabularyPronunciation(
        term: String, heard: String, kind: WordKind? = nil
    ) throws {
        let url = ConfigStore.vocabularyURL
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? "terms: {}\n"
        var updated = try insertVocabulary(term: term, heard: heard, into: original)
        if let kind { updated = setting(kind: kind, of: term, in: updated) }
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes `kind:` under the term, replacing whatever it said before.
    ///
    /// Run after `insertVocabulary`, so the term exists and any flow mapping
    /// has already been broken into lines. A term still written as a shorthand
    /// list (`Term: [a, b]`) is left alone: expanding it here would duplicate
    /// that function's job, and `kind` is a label nothing reads yet. Losing the
    /// label costs less than rewriting a line for it.
    static func setting(kind: WordKind, of term: String, in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        guard let termsIndex = lines.firstIndex(where: { $0.hasPrefix("terms:") }),
              let start = termLine(for: term, in: lines, under: termsIndex)
        else { return yaml }

        let head = lines[start]
        guard let colon = keyColon(in: head) else { return yaml }
        let value = String(head[head.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !value.hasPrefix("["), !value.hasPrefix("{") else { return yaml }

        let line = "    kind: \(kind.rawValue)"
        var cursor = start + 1
        while cursor < lines.count {
            let text = lines[cursor]
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            guard text.hasPrefix(" "), indentation(of: text).count >= 4 else { break }
            if indentation(of: text).count == 4, trimmed.hasPrefix("kind:") {
                lines[cursor] = line
                return lines.joined(separator: "\n")
            }
            cursor += 1
        }
        lines.insert(line, at: start + 1)
        return lines.joined(separator: "\n")
    }

    /// The term's own line directly under `terms:`, or nil if it is not there.
    private static func termLine(
        for term: String, in lines: [String], under termsIndex: Int
    ) -> Int? {
        var cursor = termsIndex + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            guard line.hasPrefix(" ") else { return nil }
            if indentation(of: line).count == 2, !trimmed.hasPrefix("#"),
               let colon = keyColon(in: trimmed),
               unquoted(String(trimmed[trimmed.startIndex..<colon]))
                   .caseInsensitiveCompare(term) == .orderedSame {
                return cursor
            }
            cursor += 1
        }
        return nil
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
               let colon = keyColon(in: trimmed),
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
        guard let colon = keyColon(in: head) else { return yaml }
        let value = String(head[head.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        // Shorthand list: `Term: [a, b]`, possibly wrapped over two lines.
        if value.hasPrefix("[") {
            let end = closingFlow(in: lines, from: start, deeperThan: 2)
            let sources = lines[start...end].joined(separator: " ")
            if flowListContains(heard, in: sources) { return yaml }
            guard let close = lines[end].lastIndex(of: "]") else { return yaml }
            let before = String(lines[end][lines[end].startIndex..<close])
            let separator = before.trimmingCharacters(in: .whitespaces).hasSuffix("[") ? "" : ", "
            lines[end] = before + separator + quoted(heard) + "]"
            return lines.joined(separator: "\n")
        }

        // A single-line flow mapping: `Claude: {floor: off, heard: [cloud]}`.
        // Broken into one key per line rather than parsed and rewritten, so
        // whatever it already says — `heard:`, `floor:`, both — survives
        // untouched and the new rendering only ever adds a `pronunciations:`
        // block beside it.
        if value.hasPrefix("{"), value.hasSuffix("}") {
            let pairs = splitFlowMapping(String(value.dropFirst().dropLast()))
            if pairs.contains(where: { $0.key == "heard" && flowListContains(heard, in: $0.value) }) {
                return yaml
            }
            let expanded = ["  \(quoted(term)):"]
                + pairs.map { "    \($0.key): \($0.value)" }
                + ["    pronunciations:"] + entry
            lines.replaceSubrange(start...start, with: expanded)
            return lines.joined(separator: "\n")
        }

        // A block already — `floor:`, `heard:`, `pronunciations:`, any mix —
        // or a bare (`Term:`) or legacy-floor (`Term: 0.85`) term with none
        // of them yet.
        let bodyIndent = 4
        var blockEnd = start
        var pronunciationsLine: Int?
        var heardRange: ClosedRange<Int>?
        cursor = start + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cursor += 1; continue }
            guard indentation(of: line).count >= bodyIndent else { break }
            if indentation(of: line).count == bodyIndent, trimmed.hasPrefix("pronunciations:") {
                pronunciationsLine = cursor
            }
            // The old key, possibly wrapped over two lines — cutting only the
            // first would strand the tail as invalid YAML, so its whole span
            // is tracked rather than just the one line it starts on.
            if indentation(of: line).count == bodyIndent, trimmed.hasPrefix("heard:") {
                let end = closingFlow(in: lines, from: cursor, deeperThan: bodyIndent)
                heardRange = cursor...end
                blockEnd = end
                cursor = end + 1
                continue
            }
            blockEnd = cursor
            cursor += 1
        }

        if let heardRange, flowListContains(heard, in: lines[heardRange].joined(separator: " ")) {
            return yaml
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
            if let colon = keyColon(in: trimmed),
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
        if let colon = keyColon(in: head),
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

    /// Whether `item` is one of a flow sequence's entries, exactly — not
    /// merely a substring of a longer one. "Press" is not "Pressy", and a
    /// bare `contains` over the raw text said it was, so a rendering that
    /// happened to be a prefix of one already there was silently dropped.
    private static func flowListContains(_ item: String, in text: String) -> Bool {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"),
              open < close else { return false }
        return text[text.index(after: open)..<close]
            .split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .contains { $0.caseInsensitiveCompare(item) == .orderedSame }
    }

    /// A one-line flow mapping's entries, split on its own top-level commas —
    /// `{floor: off, heard: [cloud, cloude]}` has a comma inside `heard:`'s
    /// list that is not one of the mapping's own separators.
    private static func splitFlowMapping(_ inner: String) -> [(key: String, value: String)] {
        var depth = 0
        var pieces: [String] = [""]
        for character in inner {
            if character == "[" || character == "{" { depth += 1 }
            if character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                pieces.append("")
            } else {
                pieces[pieces.count - 1].append(character)
            }
        }
        return pieces.compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { return nil }
            let key = unquoted(String(trimmed[trimmed.startIndex..<colon]))
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
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

    /// The colon that ends a YAML key, skipping any inside a quoted one.
    ///
    /// `quoted` wraps a term that carries a colon, so `"ACME: Cloud":` has two
    /// of them and only the last one separates key from value. Splitting on
    /// the first looked for a term called `"ACME`. It found none, so `kind:`
    /// was dropped and the next rendering wrote the term a second time.
    ///
    /// A quote only delimits when the key opens with one. `O'Brien:` is a
    /// plain key and its apostrophe is an ordinary letter — a scanner that
    /// took every quote as a delimiter lost that colon instead, which is the
    /// same bug the other way round.
    private static func keyColon(in line: String) -> String.Index? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }

        let quote = line[index]
        if quote == "\"" || quote == "'" {
            index = line.index(after: index)
            while index < line.endIndex {
                if quote == "\"", line[index] == "\\" {
                    index = line.index(after: index)
                    if index == line.endIndex { break }
                } else if line[index] == quote {
                    // A single-quoted scalar writes its own quote as `''`.
                    let next = line.index(after: index)
                    if quote == "'", next < line.endIndex, line[next] == "'" {
                        index = line.index(after: next)
                        continue
                    }
                    index = next
                    break
                }
                index = line.index(after: index)
            }
        }

        while index < line.endIndex {
            if line[index] == ":" { return index }
            index = line.index(after: index)
        }
        return nil
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
