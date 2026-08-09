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

    /// Records that `heard` should be written as `corrected`. False when
    /// nothing was written.
    ///
    /// **A revert writes no rule.** When `heard` names a vocabulary term and
    /// `corrected` does not, the speaker is taking the term back: the app wrote
    /// `Praisy`, they meant "praise". Writing `"praise": ["Praisy"]` here would
    /// rewrite *every* `Praisy` into "praise" from then on, correct ones
    /// included — one revert silently disabling the term. And a rule in
    /// `config.yaml` is one `--forget` cannot reach, so the only way back out
    /// was to find it by hand.
    ///
    /// The gate sits here rather than only in the caller because this is the
    /// last function before the file, and all three correction paths reach it.
    /// A path added later cannot bring the bug back.
    @discardableResult
    static func addReplacement(heard: String, corrected: String) throws -> Bool {
        if let term = revertedTerm(heard: heard, corrected: corrected) {
            Log.write("correction: \"\(heard)\" -> \"\(corrected)\" takes back the term"
                + " \(term), so no replacement rule was written — a rule here would"
                + " rewrite every \(term) into \"\(corrected)\"")
            return false
        }
        let url = ConfigStore.fileURL
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = try insert(heard: heard, corrected: corrected, into: original)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// The vocabulary term a correction takes back, when it takes one back.
    ///
    /// Two conditions, and both matter. `heard` has to name a term, or this is
    /// an ordinary correction of an ordinary word. And `corrected` has to name
    /// no term at all: `Supabase` corrected into `Redcrawl` is one term written
    /// where another was said, which is a rendering worth recording, not a
    /// statement that the vocabulary was wrong to fire.
    ///
    /// - Parameter vocabulary: the table to ask, when the caller already has
    ///   one. Read from disk otherwise, which is what the three correction
    ///   paths do.
    static func revertedTerm(
        heard: String, corrected: String, in vocabulary: Config.Vocabulary? = nil
    ) -> String? {
        let terms = (vocabulary ?? ConfigStore.loadVocabulary()).terms.keys
        guard let term = terms.first(where: {
            $0.caseInsensitiveCompare(heard) == .orderedSame
        }) else { return nil }
        guard !terms.contains(where: {
            $0.caseInsensitiveCompare(corrected) == .orderedSame
        }) else { return nil }
        return term
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
        let end = openBlockBody(of: term, at: start, in: &lines)

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

    // MARK: - Taking a rendering back, and recording what it collided with

    /// What `discountPronunciation` managed to do about a rendering.
    enum Discount: Equatable {
        /// Its `seen:` count went down to this.
        case reduced(Int)
        /// It stood at one sighting from one correction, and that correction
        /// has now been contradicted, so the entry is gone.
        case dropped
        /// It is there and it cannot be counted down: a legacy `heard:` list,
        /// or an entry with `seen: 0`, which means "never counted". There is no
        /// honest number to subtract one from.
        case uncounted
        /// No such rendering. Nothing in the file caused the substitution.
        case notFound
    }

    /// Takes one sighting back off a rendering, because the speaker said the
    /// term should not have fired there.
    ///
    /// A revert is a person contradicting a rendering they once confirmed, so
    /// the count that recorded it goes down. It only ever goes down by one: a
    /// rendering seen nine times and reverted once is still how this person
    /// says the word, and deleting it would be the same bug in the other
    /// direction — one correction disabling a term.
    ///
    /// **The entry is only removed at zero, and only when a correction wrote
    /// it.** `seen: 1, from: correction` reverted once is one sighting against
    /// one revert: nothing left. A mined or legacy entry has `seen: 0`, which
    /// means "never counted" rather than "never seen", so there is no number to
    /// take one off — it is left alone and reported as `uncounted`. Deleting on
    /// a count nobody recorded is how a prune eats correct data, and
    /// `Corrections.prune` refuses for the same reason.
    static func discountPronunciation(term: String, heard: String) throws -> Discount {
        let url = ConfigStore.vocabularyURL
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            return .notFound
        }
        var lines = original.components(separatedBy: "\n")
        guard let start = index(ofTerm: term, in: lines) else { return .notFound }
        let termIndent = indentation(of: lines[start]).count
        let end = endOfTermBlock(in: lines, from: start, deeperThan: termIndent)

        var listAt: Int?
        for cursor in (start + 1)...max(start + 1, end) where cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("pronunciations:") {
                listAt = cursor
                break
            }
        }
        // No block at all: whatever is there is a legacy `heard:` list, which
        // carries no count. `Corrections` has already established the rendering
        // exists, so this is `uncounted` and not `notFound`.
        guard let listAt else { return .uncounted }
        let listEnd = endOfTermBlock(
            in: lines, from: listAt, deeperThan: indentation(of: lines[listAt]).count
        )
        guard let found = entry(named: heard, in: lines, from: listAt + 1, through: listEnd) else {
            return .uncounted
        }
        let last = endOfEntry(in: lines, from: found, through: listEnd)
        let seen = value(of: "seen", in: lines, from: found, through: last)
        let source = word(of: "from", in: lines, from: found, through: last)

        if let seen, seen >= 2 {
            _ = set("seen", to: seen - 1, in: &lines, from: found, through: last)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return .reduced(seen - 1)
        }
        guard seen == 1, source == "correction" else { return .uncounted }
        lines.removeSubrange(found...last)
        // A `pronunciations:` key with nothing under it decodes as null, not as
        // an empty list, so it goes too.
        if endOfTermBlock(
            in: lines, from: listAt, deeperThan: indentation(of: lines[listAt]).count
        ) == listAt {
            lines.remove(at: listAt)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return .dropped
    }

    /// Records that `term` was written over the ordinary word `word`, and
    /// returns the pair's counts afterwards.
    ///
    /// Written under the term as `collides_with:`, which nothing matches and
    /// nothing substitutes — see `Config.Vocabulary.Term.Collision`. It is not
    /// a rendering: a rendering says "the term was said and came out like
    /// this", and this says the opposite, that the term was *not* said here.
    /// Putting the two in one list is how a revert would end up firing as a
    /// rule, which is the bug this whole change exists to fix.
    ///
    /// Keyed on the pair. "praise" is a negative for `Praisy` and says nothing
    /// at all about `Supabase`, so it lives under the term it argues with.
    ///
    /// - Parameter clips: how many negative clips this revert added, 0 or 1.
    @discardableResult
    static func recordCollision(
        term: String, word: String, clips: Int
    ) throws -> (reverted: Int, clips: Int) {
        let url = ConfigStore.vocabularyURL
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let (updated, counts) = recording(
            collision: word, of: term, clips: clips, in: original
        )
        if updated != original {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
        return counts
    }

    /// The file with one collision recorded, and what the pair now stands at.
    static func recording(
        collision word: String, of term: String, clips: Int, in yaml: String
    ) -> (String, (reverted: Int, clips: Int)) {
        var lines = yaml.components(separatedBy: "\n")
        guard let start = index(ofTerm: term, in: lines) else { return (yaml, (0, 0)) }
        let termIndent = indentation(of: lines[start])
        let bodyIndent = termIndent + "  "
        let end = openBlockBody(of: term, at: start, in: &lines)

        var listIndex: Int?
        var cursor = start + 1
        while cursor <= end, cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("collides_with:") {
                listIndex = cursor
                break
            }
            cursor += 1
        }

        guard let listAt = listIndex else {
            lines.insert(contentsOf: [
                "\(bodyIndent)collides_with:",
                "\(bodyIndent)  - word: \(quoted(word))",
                "\(bodyIndent)    reverted: 1",
                "\(bodyIndent)    clips: \(clips)",
            ], at: end + 1)
            return (lines.joined(separator: "\n"), (1, clips))
        }

        // `collides_with: [praise]` is legal YAML and nothing writes it, but a
        // person may have. Left alone rather than rewritten, for the reason
        // `adding(pronunciation:)` leaves a flow `pronunciations:` alone:
        // appending a block entry under a flow sequence would not parse.
        let listIndent = indentation(of: lines[listAt])
        if lines[listAt].trimmingCharacters(in: .whitespaces).dropFirst("collides_with:".count)
            .trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            return (yaml, (0, 0))
        }

        let listEnd = endOfTermBlock(in: lines, from: listAt, deeperThan: listIndent.count)
        let entryIndent = listIndent + "  "
        if let found = entry(named: word, under: "word", in: lines, from: listAt + 1, through: listEnd) {
            // The entry's last line is recomputed before each counter, because
            // writing the first one can insert a line and move it.
            func bump(_ key: String, by delta: Int) -> Int {
                let listEnd = endOfTermBlock(in: lines, from: listAt, deeperThan: listIndent.count)
                let last = endOfEntry(in: lines, from: found, through: listEnd)
                return add(
                    delta, to: key, in: &lines, from: found, through: last,
                    indent: entryIndent + "  "
                )
            }
            let reverted = bump("reverted", by: 1)
            let kept = bump("clips", by: clips)
            return (lines.joined(separator: "\n"), (reverted, kept))
        }

        lines.insert(contentsOf: [
            "\(entryIndent)- word: \(quoted(word))",
            "\(entryIndent)  reverted: 1",
            "\(entryIndent)  clips: \(clips)",
        ], at: listEnd + 1)
        return (lines.joined(separator: "\n"), (1, clips))
    }

    /// Removes a term's whole `collides_with:` block, and says how many pairs
    /// went. For `--forget`, which has to take back all four things a revert
    /// wrote.
    static func dropCollisions(of term: String) throws -> Int {
        let url = ConfigStore.vocabularyURL
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var lines = original.components(separatedBy: "\n")
        guard let start = index(ofTerm: term, in: lines) else { return 0 }
        let termIndent = indentation(of: lines[start]).count
        let end = endOfTermBlock(in: lines, from: start, deeperThan: termIndent)

        var listAt: Int?
        for cursor in (start + 1)...max(start + 1, end) where cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("collides_with:") {
                listAt = cursor
                break
            }
        }
        guard let listAt else { return 0 }
        let listIndent = indentation(of: lines[listAt]).count
        let listEnd = endOfTermBlock(in: lines, from: listAt, deeperThan: listIndent)
        // The flow shape a person may have written: `collides_with: [praise]`.
        let inline = lines[listAt].trimmingCharacters(in: .whitespaces)
            .dropFirst("collides_with:".count).trimmingCharacters(in: .whitespaces)
        var removed = 0
        if inline.hasPrefix("[") {
            removed = count(inFlow: lines[listAt...listEnd].joined(separator: " "))
        } else {
            for cursor in listAt...listEnd
            where lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                removed += 1
            }
        }
        lines.removeSubrange(listAt...listEnd)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return removed
    }

    /// The term's value in block form, with its last line's index.
    ///
    /// A term can be written five ways and only one of them has room for
    /// another key underneath. `Praisy: [Prissy]` and `Mirza: 0.85` are
    /// rewritten as `heard:` and `floor:` inside a block body — both are still
    /// read, so nothing is lost — and a term that already has a body is left
    /// exactly as it is.
    ///
    /// **A value that wraps keeps its own lines.** The live file writes one
    /// list over two, and joining them onto one line destroys the entry when
    /// any of them carries a comment: everything after the `#` becomes part of
    /// the comment, so `[Prissy,   # the common one` + `Pressy]` collapses to
    /// an unclosed bracket, and the whole of `vocabulary.yaml` then fails to
    /// load — silently, because a file that will not parse is read as no terms
    /// at all. Only the first line is rewritten, and the continuations move
    /// under the new key untouched. They stay indented deeper than it, which is
    /// all a flow sequence asks.
    private static func openBlockBody(
        of term: String, at start: Int, in lines: inout [String]
    ) -> Int {
        let termIndent = indentation(of: lines[start])
        let bodyIndent = termIndent + "  "
        let head = lines[start]
        guard let colon = head.firstIndex(of: ":") else {
            return endOfTermBlock(in: lines, from: start, deeperThan: termIndent.count)
        }
        let inline = String(head[head.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !inline.isEmpty, !inline.hasPrefix("#") else {
            return endOfTermBlock(in: lines, from: start, deeperThan: termIndent.count)
        }
        let closes = closingFlow(in: lines, from: start, deeperThan: termIndent.count)
        // A bare list is the old `heard:`; a bare number is the old `floor:`.
        let key = inline.hasPrefix("[") ? "heard" : "floor"
        var rewritten = [
            "\(termIndent)\(quoted(term)):",
            "\(bodyIndent)\(key): \(inline)",
        ]
        if closes > start { rewritten += lines[(start + 1)...closes] }
        lines.replaceSubrange(start...closes, with: rewritten)
        return closes + 1
    }

    /// A number written on one of an entry's lines, if it is there.
    private static func value(
        of key: String, in lines: [String], from: Int, through last: Int
    ) -> Int? {
        Int(word(of: key, in: lines, from: from, through: last) ?? "")
    }

    /// A scalar written on one of an entry's lines, if it is there.
    private static func word(
        of key: String, in lines: [String], from: Int, through last: Int
    ) -> String? {
        for cursor in from...max(from, last) where cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("-")
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            guard body.hasPrefix("\(key):") else { continue }
            return unquoted(String(body.dropFirst(key.count + 1)))
        }
        return nil
    }

    /// Writes a number onto an entry's existing key. False if it had none.
    @discardableResult
    private static func set(
        _ key: String, to number: Int, in lines: inout [String], from: Int, through last: Int
    ) -> Bool {
        for cursor in from...max(from, last) where cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("-")
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            guard body.hasPrefix("\(key):") else { continue }
            // A key on the `- ` line itself keeps its dash.
            let head = trimmed.hasPrefix("-")
                ? "\(indentation(of: lines[cursor]))- " : indentation(of: lines[cursor])
            lines[cursor] = "\(head)\(key): \(number)"
            return true
        }
        return false
    }

    /// Adds `delta` to an entry's counter, writing the key when it has none.
    /// Returns what it now stands at.
    private static func add(
        _ delta: Int, to key: String, in lines: inout [String],
        from: Int, through last: Int, indent: String
    ) -> Int {
        let was = value(of: key, in: lines, from: from, through: last) ?? 0
        if set(key, to: was + delta, in: &lines, from: from, through: last) {
            return was + delta
        }
        lines.insert("\(indent)\(key): \(was + delta)", at: last + 1)
        return was + delta
    }

    /// The line of `- heard: <name>` inside a `pronunciations:` block, or of
    /// `- word: <name>` inside a `collides_with:` one.
    private static func entry(
        named heard: String, under key: String = "heard",
        in lines: [String], from: Int, through last: Int
    ) -> Int? {
        for cursor in from...max(from, last) where cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { continue }
            let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            // `- heard: Versal` and the bare `- Versal` a person may have typed.
            let spelling: String
            if body.hasPrefix("\(key):") {
                spelling = unquoted(String(body.dropFirst(key.count + 1)))
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
