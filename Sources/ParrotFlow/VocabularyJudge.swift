import Foundation

/// Judges a whole reading, not one word at a time.
///
/// The vocabulary pass matches on sound and cannot read the sentence, so it
/// finds names in ordinary words that happen to sound like one. Asking one
/// YES/NO per substitution is the right shape when there is one substitution
/// and cannot express the answer when there are two:
///
///     heard:  Mira and Mirza … deployed on Versailles … the Versailles castle
///     meant:  Mira and Mirza … deployed on Vercel     … the Versailles castle
///
/// One word, two answers, one sentence.
///
/// So this builds every reading the proposals allow and asks the model to pick
/// one. The model returns a letter. The letter is looked up here — the model
/// never writes the transcript, which is what stops it tidying the grammar on
/// the way past. Measured: a prompt asked to return the corrected sentence
/// mangled 15 of 58 inputs. This shape cannot, because the output is chosen
/// from a list this file built.
///
/// ## Why it is in the app
///
/// It was a Python transform reading `vocabulary.proposals` out of a JSON
/// variable. Four of the prototype's bugs lived in that hand-off (F5, F9): the
/// positions had to be re-derived from occurrence counts, the JSON escaped two
/// characters out of the ones that need it, and a config that installed the
/// script without rebuilding the app left the judge silently off. Nothing
/// crosses a process boundary now, so nothing can be re-derived wrongly.
///
/// The prompt stays a file the user owns. Everything below is mechanical and
/// would be wrong to ask a model for: which words are uncertain, what the
/// readings are, and which sentence a letter stands for.
enum VocabularyJudge {

    /// How large a menu is allowed to get. Optional stage params, because they
    /// are the numbers a person tuning their own pipeline wants to move, and an
    /// environment variable is not something a config file can say.
    struct Caps: Equatable, Codable {
        /// Uncertain positions, not proposals. One rule can rewrite three
        /// words. Past this many the stage keeps what the decoder wrote and
        /// says so — a menu nobody can read decides nothing.
        var slots = 4
        /// The menu, not the slot count, is what the model is bad at. Three
        /// binary slots is eight readings and was the most that measured
        /// useful, so sixteen is the ceiling — a slot offering three readings
        /// costs another slot its second one.
        var readings = 16
        /// Readings per slot, the decoder's own included. Two alternatives is
        /// what a lettered list stays readable at.
        var perSlot = 3

        static let standard = Caps()

        /// What the alphabet allows. The menu is lettered, so a 27th reading
        /// would be a second `A` and the reply could not name it.
        static let letterCeiling = 26

        /// What is wrong with these numbers, in the words `--check-config`
        /// uses. A cap of zero silences the stage on every transcript, which
        /// reads as the judge being broken rather than as a number being wrong.
        var problems: [String] {
            var found: [String] = []
            for (name, value) in [
                ("max_slots", slots), ("max_readings", readings), ("max_per_slot", perSlot),
            ] where value < 1 {
                found.append("vocabulary: \(name) is \(value) — it has to be at least 1")
            }
            if readings > Self.letterCeiling {
                found.append("vocabulary: max_readings is \(readings), and the menu is"
                    + " lettered — \(Self.letterCeiling) is the most that can be named")
            }
            return found
        }
    }

    /// One place in the sentence still in question, and the readings of it.
    struct Slot {
        let range: Range<String.Index>
        /// The decoder's own reading first, always. Measured on
        /// `tests/judge-cases.yaml` with gemma4:e4b, the only change being
        /// which reading sits at A:
        ///
        ///     untouched first    approve 69%   decline 74%   overall 72%
        ///     substituted first  approve 94%   decline 52%   overall 64%
        ///
        /// The second row is a model agreeing with whatever it is shown first,
        /// which reads as confidence and is worth eight points of damage.
        var options: [String]
        /// The vocabulary terms this slot is about, for `{terms}`.
        let terms: [String]
    }

    /// One proposal reduced to what the menu needs: a span, what stands there
    /// now, and the other reading of it.
    ///
    /// Two sources fill this. The acoustic pass hands over a span holding the
    /// *decoded* word with the term as the alternative; a `replacements` rule
    /// has already rewritten the text, so its span holds the term and the
    /// decoded word is what has to be offered back.
    struct Part {
        let range: Range<String.Index>
        /// What the decoder wrote here, whether or not it is what stands there.
        let decoded: String
        /// The other reading.
        let other: String
        /// The vocabulary term at stake, for `{terms}`.
        let term: String
    }

    // MARK: - Gathering

    /// The proposals the pass left undecided, as parts of a menu.
    ///
    /// A proposal carries a range in the text the pass returned. When an
    /// earlier stage has edited that text the range is stale, so each one is
    /// checked against the words it claims to cover and re-anchored when it
    /// moved. A proposal whose words are gone is dropped rather than guessed
    /// at — the reading that rewrites the wrong noun is worse than no reading
    /// (F3).
    static func acousticParts(
        _ proposals: [Vocabulary.Proposal], in text: String, measuredOn pass: String
    ) -> [Part] {
        var parts: [Part] = []
        // Occurrences already handed to some other span of the same spelling.
        // Two readings *of one span* — `Praisy` and `Praisy's` over "praise" —
        // are the case this stage exists for and must land on top of each
        // other, so the claim is per span, not per proposal.
        var taken: [String: [Range<String.Index>]] = [:]
        var resolved: [String: Range<String.Index>] = [:]
        // Sorted by where they were, so the re-anchoring below assigns spans
        // left to right and two proposals sharing a spelling keep their order.
        let wanted = proposals
            .filter { !$0.applied && !$0.heard.isEmpty && $0.heard != $0.term }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        for proposal in wanted {
            // Offsets rather than the index itself. A `String.Index` belongs to
            // the string it was made from, and `text` is a different string
            // once any stage above has touched it (F13).
            let was = pass.distance(from: pass.startIndex, to: proposal.range.lowerBound)
            let span = "\(was)\u{0}\(proposal.heard)"
            if let already = resolved[span] {
                parts.append(Part(
                    range: already, decoded: proposal.heard,
                    other: proposal.term, term: proposal.term
                ))
                continue
            }
            var range = Self.at(offset: was, holding: proposal.heard, in: text)
            if range == nil {
                // The text moved under the proposal. Re-anchored to the nearest
                // occurrence of the same words rather than to the *n*th one: a
                // counter labelled the second `Versailles` in one sentence as
                // the first, so the menu rewrote the castle and left the
                // deployment alone (F3).
                let claimed = taken[proposal.heard] ?? []
                range = Vocabulary.spans(of: proposal.heard, in: text)
                    .filter { hit in !claimed.contains { $0 == hit } }
                    .min { left, right in
                        let a = abs(text.distance(from: text.startIndex, to: left.lowerBound) - was)
                        let b = abs(text.distance(from: text.startIndex, to: right.lowerBound) - was)
                        return a < b
                    }
                if range != nil {
                    Log.write("vocabulary judge: \"\(proposal.heard)\" moved since the pass"
                        + " read it; re-anchored to the nearest occurrence")
                }
            }
            guard let found = range else {
                Log.write("vocabulary judge: \"\(proposal.heard)\" is no longer in the"
                    + " transcript; that reading is not offered")
                continue
            }
            taken[proposal.heard, default: []].append(found)
            resolved[span] = found
            parts.append(Part(
                range: found, decoded: proposal.heard,
                other: proposal.term, term: proposal.term
            ))
        }
        return parts
    }

    /// The span at `offset` when it still holds `phrase`, and nil when it does
    /// not — which is how "nothing above me edited the text" is checked.
    private static func at(
        offset: Int, holding phrase: String, in text: String
    ) -> Range<String.Index>? {
        guard offset >= 0,
              let from = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex),
              let to = text.index(from, offsetBy: phrase.count, limitedBy: text.endIndex),
              text[from..<to] == phrase
        else { return nil }
        return from..<to
    }

    /// The same, for substitutions a `replacements` rule already made.
    ///
    /// A rule has no position to publish — it fired during the `replacements`
    /// stage, which rewrites text and reports pairs. So these are found by
    /// searching for the term, which is the least-resistance path this plan
    /// settled on rather than teaching `replacements` to publish ranges. A rule
    /// fires on an exact spelling and so proposes far less often than the
    /// acoustic pass, which is why the same shortcut was not survivable there.
    ///
    /// **A term the decoder already wrote is not a substitution.** Searching
    /// for the term finds every occurrence, including the ones no rule touched
    /// — and a slot built on one of those puts the *rule's source spelling*
    /// first on the menu, in the place the model agrees with most readily. So
    /// "deployed on Vercel and the Versailles castle" would be offered
    /// "deployed on Versailles" as the decoder's own reading, which it never
    /// was.
    ///
    /// `before` is the transcript as the acoustic pass returned it, which is
    /// what `replacements` was handed, and it says which occurrence is which.
    /// A rule rewrites in place and reorders nothing, so the terms standing in
    /// the text now are, in order, the occurrences of `heard` and of `term` in
    /// `before` — and only the first kind is a substitution to offer back. See
    /// `rewritten(_:_:in:became:)`.
    ///
    /// When the two do not line up, some other rule wrote the term as well and
    /// nothing here can say which occurrence came from where. Then none of them
    /// are offered, and the log says so.
    ///
    /// A rule whose source is a pattern is skipped. `/(\w+) dot (\w+)/` names
    /// no spelling to offer back, and putting the pattern on a menu would ask
    /// the model to choose a regular expression.
    static func ruleParts(_ changes: String, in text: String, before: String?) -> [Part] {
        var parts: [Part] = []
        for pair in changes.split(separator: ";") {
            let pairText = pair.split(separator: "@").first.map(String.init) ?? String(pair)
            guard let arrow = pairText.range(of: "->") else { continue }
            let heard = pairText[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let term = pairText[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, !term.isEmpty, heard != term,
                  !heard.hasPrefix("/"), !term.contains("$")
            else { continue }
            let standing = Vocabulary.spans(of: term, in: text, ignoringCase: true)
            guard let before else {
                for range in standing {
                    parts.append(Part(range: range, decoded: heard, other: heard, term: term))
                }
                continue
            }
            guard let mine = rewritten(heard, term, in: before, became: standing.count) else {
                Log.write("vocabulary judge: \"\(term)\" stands \(standing.count) time(s) and"
                    + " the transcript before the rules cannot account for that many;"
                    + " \"\(heard)\" is not offered back")
                continue
            }
            for index in mine {
                parts.append(Part(
                    range: standing[index], decoded: heard, other: heard, term: term
                ))
            }
        }
        return parts
    }

    /// Which of the terms standing in the text now were written by this rule.
    ///
    /// The rule turns every `heard` into `term` and leaves every `term` where
    /// it was. It rewrites in place, so the order is preserved: the *i*-th term
    /// in the text now is the *i*-th of those two kinds of occurrence in the
    /// text before. The ones that were `heard` are the substitutions; the rest
    /// were already right and must not be offered a reading the decoder never
    /// produced.
    ///
    /// Nil when the counts disagree, which means something other than this rule
    /// also wrote the term. Guessing there is how a correct word gets a wrong
    /// spelling put first on the menu.
    static func rewritten(
        _ heard: String, _ term: String, in before: String, became standing: Int
    ) -> [Int]? {
        var marks: [(at: String.Index, rule: Bool)] =
            Vocabulary.spans(of: heard, in: before, ignoringCase: true)
                .map { ($0.lowerBound, true) }
            + Vocabulary.spans(of: term, in: before, ignoringCase: true)
                .map { ($0.lowerBound, false) }
        marks.sort { $0.at < $1.at }
        guard marks.count == standing else { return nil }
        return marks.indices.filter { marks[$0].rule }
    }

    // MARK: - Slots and readings

    /// Every position still in question, left to right, as one slot each.
    ///
    /// Overlapping spans used to be dropped, earliest wins. That was right when
    /// they were competing substitutions and wrong now they are readings of the
    /// same words: `Praisy` decoded as "praise he" arrives as both "praise" and
    /// "praise he", and dropping one leaves a menu where every option strands a
    /// word. So they are grouped, and the slot covers the widest of them.
    ///
    /// A slot with one reading is not a question, so it is left out.
    static func slots(in text: String, from parts: [Part], caps: Caps) -> [Slot] {
        let sorted = parts.sorted { left, right in
            left.range.lowerBound == right.range.lowerBound
                ? left.range.upperBound < right.range.upperBound
                : left.range.lowerBound < right.range.lowerBound
        }
        var groups: [(range: Range<String.Index>, parts: [Part])] = []
        for part in sorted {
            if let last = groups.last, part.range.lowerBound < last.range.upperBound {
                groups[groups.count - 1].range =
                    last.range.lowerBound..<max(last.range.upperBound, part.range.upperBound)
                groups[groups.count - 1].parts.append(part)
            } else {
                groups.append((part.range, [part]))
            }
        }

        var built: [Slot] = []
        for group in groups {
            let span = group.range
            /// The group's words with one part rewritten.
            func written(_ part: Part, _ word: String) -> String {
                String(text[span.lowerBound..<part.range.lowerBound]) + word
                    + String(text[part.range.upperBound..<span.upperBound])
            }

            // The decoder's own reading goes first, and for a rule that is not
            // the text — the rule already rewrote it.
            var options = [String(text[span])]
            for part in group.parts where String(text[part.range]) != part.decoded {
                options = [written(part, part.decoded)]
                break
            }

            var widths: [String: Int] = [:]
            for part in group.parts {
                let reading = written(part, part.other)
                guard widths[reading] == nil else { continue }
                widths[reading] = text.distance(
                    from: part.range.lowerBound, to: part.range.upperBound
                )
            }
            var rest: [String] = []
            for part in group.parts.sorted(by: { left, right in
                text.distance(from: left.range.lowerBound, to: left.range.upperBound)
                    < text.distance(from: right.range.lowerBound, to: right.range.upperBound)
            }) {
                let reading = written(part, part.other)
                if !options.contains(reading), !rest.contains(reading) { rest.append(reading) }
            }
            let plain = String(text[span])
            if !options.contains(plain), !rest.contains(plain) { rest.append(plain) }

            // Widest first, possessive as the tiebreak. The other way round
            // cost three cases: a wide span and its possessive are the same
            // width, and ranking possessives last dropped `Praisy's` over
            // "praise his" in favour of `Praisy` over "his" — which leaves the
            // stranded word the wide span exists to absorb.
            //
            // Sorted by index as the final key so equal ranks keep the order
            // they were built in, which Swift's sort does not promise.
            let possessive = { (reading: String) in
                reading.hasSuffix("'s") || reading.contains("'s ")
            }
            let ranked = rest.enumerated().sorted { left, right in
                let a = (widths[left.element] ?? 0, possessive(left.element), left.offset)
                let b = (widths[right.element] ?? 0, possessive(right.element), right.offset)
                if a.0 != b.0 { return a.0 > b.0 }
                if a.1 != b.1 { return !a.1 }
                return a.2 < b.2
            }.map(\.element)

            let kept = [options[0]] + ranked.prefix(max(0, caps.perSlot - 1))
            guard kept.count > 1 else { continue }
            built.append(Slot(
                range: span, options: kept,
                terms: Array(Set(group.parts.map(\.term))).sorted()
            ))
        }
        return built
    }

    /// Every sentence the slots allow, the untouched one first.
    ///
    /// First is the reading with no proposal written in — what the decoder
    /// produced. That is the answer this stage exists to make reachable, and
    /// burying it costs declines.
    ///
    /// A slot can offer more than two readings, so the menu is trimmed rather
    /// than the slot count capped. Speculative readings — the wider spans,
    /// which sort last — go first, because a menu longer than eight measured
    /// worse than a menu missing its least likely entry.
    static func readings(
        in text: String, from slots: [Slot], caps: Caps
    ) -> (sentences: [String], choices: [[Int]], slots: [Slot], truncated: Bool) {
        // The alphabet is the hard ceiling whatever the config says: a 27th
        // reading would be a second `A`, and the reply could not name it. The
        // trim below cannot always get under the cap on its own — it stops at
        // two readings a slot, so five binary slots is thirty-two menus and no
        // trimming left to do — so the enumeration is bounded as well.
        let ceiling = max(1, min(caps.readings, Caps.letterCeiling))
        var trimmed = slots
        while true {
            // Stopped at the ceiling rather than multiplied out. `max_slots` is
            // a number in a config file, and sixty binary slots is 2^60 — a
            // number this only ever compares against 26, and one that overflows
            // and traps on the way to being compared.
            let total = trimmed.reduce(1) { running, slot in
                running > ceiling ? running : running * slot.options.count
            }
            guard total > ceiling, !trimmed.isEmpty else { break }
            // The first of the widest, not the last: the leftmost slot is the
            // one a reader meets first, and Swift's `max(by:)` picks the last
            // of equal elements.
            var widest = 0
            for index in trimmed.indices
            where trimmed[index].options.count > trimmed[widest].options.count {
                widest = index
            }
            guard trimmed[widest].options.count > 2 else { break }
            trimmed[widest].options.removeLast()
        }

        var sentences: [String] = []
        var choices: [[Int]] = []
        var truncated = false
        // The last slot varies fastest, so the first combination is every
        // slot's first option — the decoder's own sentence.
        var combination = Array(repeating: 0, count: trimmed.count)
        while true {
            var candidate = ""
            var cursor = text.startIndex
            for (slot, pick) in zip(trimmed, combination) {
                candidate += text[cursor..<slot.range.lowerBound]
                candidate += slot.options[pick]
                cursor = slot.range.upperBound
            }
            candidate += text[cursor...]
            // The combination travels with the sentence. Which slots were left
            // alone cannot be recovered from the finished string — one word can
            // fill two slots and go two different ways, which is the case this
            // stage exists for.
            if !sentences.contains(candidate) {
                sentences.append(candidate)
                choices.append(combination)
            }
            if sentences.count >= ceiling { truncated = true; break }
            var index = trimmed.count - 1
            while index >= 0 {
                combination[index] += 1
                if combination[index] < trimmed[index].options.count { break }
                combination[index] = 0
                index -= 1
            }
            if index < 0 { break }
        }
        return (sentences, choices, trimmed, truncated)
    }

    // MARK: - The evidence

    /// How clearly each uncertain word was heard, as words rather than sums.
    ///
    /// The numbers are log-probabilities with the vocabulary bonus already
    /// taken out by `Vocabulary.apply`, so the two spellings are comparable —
    /// the older block showed the boosted figure, which said the term was heard
    /// more clearly when often it was not (F4).
    ///
    /// The difference is precomputed. A small model is unreliable at arithmetic
    /// on negative numbers, and this judge has already measured that asking it
    /// for more reasoning costs accuracy.
    ///
    /// A proposal with no scores contributes no line. It used to contribute a
    /// line reading `"his" 0.00 "Praisy" -3.88 — "Praisy" heard 3.9 less
    /// clearly`, which claims the recogniser heard "his" perfectly. Nothing
    /// measured that. Measured on gemma4:e4b, 10 of 33 cached menus carried
    /// one, and taking them out was worth two cases (F6).
    static func scoreBlock(_ proposals: [Vocabulary.Proposal]) -> String {
        var lines: [String] = []
        var seen: Set<String> = []
        for proposal in proposals where !proposal.applied {
            guard let heard = proposal.heardScore, let term = proposal.termScore,
                  !proposal.heard.isEmpty, !proposal.term.isEmpty
            else { continue }
            let key = "\(proposal.heard)\u{0}\(proposal.term)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let worse = term < heard ? proposal.term : proposal.heard
            lines.append(String(
                format: "  \"%@\" %.2f   \"%@\" %.2f   — \"%@\" heard %.1f less clearly",
                proposal.heard, heard, proposal.term, term, worse, abs(heard - term)
            ))
        }
        guard !lines.isEmpty else { return "" }
        return "\n\nHow clearly the recogniser heard each spelling over that stretch of\n"
            + "audio. Closer to zero is clearer, and the vocabulary's own bonus has been\n"
            + "taken out, so the two are comparable.\n\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - Asking

    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// The menu as the model sees it.
    static func menu(_ sentences: [String]) -> String {
        sentences.enumerated()
            .map { "\(letters[$0.offset % letters.count]). \($0.element)" }
            .joined(separator: "\n")
    }

    /// The letter the reply names, read loosely.
    ///
    /// A model that answers "B." or "Option B" has decided and formatted it
    /// badly, and refusing that is refusing a correct answer.
    ///
    /// **A letter standing on its own is the answer.** Reading the first letter
    /// of any kind takes "The answer is C" as A, and reading the first letter
    /// that merely names an option takes "Option B" as O once the menu is
    /// fifteen long — the same mistake with a bigger menu. So the reply is cut
    /// into words and the first one-letter word that names an option wins.
    ///
    /// Apostrophes count as letters for that cut, so "I'd pick D" is three
    /// words and the answer is D rather than I.
    ///
    /// The old rule is the fallback, for a reply with no bare letter in it at
    /// all. It is what `scripts/tune-judge.py` does, so the harness and the app
    /// still agree about every reply either of them can read.
    static func chosen(_ reply: String, of count: Int) -> Int? {
        let upper = reply.uppercased()
        let words = upper.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
        for word in words where word.count == 1 {
            guard let index = letters.firstIndex(of: word[word.startIndex]) else { continue }
            if index < count { return index }
        }
        for character in upper {
            guard let index = letters.firstIndex(of: character) else { continue }
            if index < count { return index }
        }
        return nil
    }

    /// The menu and the system message, appended to `PARROTFLOW_JUDGE_DUMP`.
    ///
    /// A harness wants to know whether the right sentence was ever offered.
    /// Two failures wear the same face in a transcript — a menu without the
    /// true reading, and a judge that picked the wrong one — and only the first
    /// is worth widening the proposals for. The system message goes in too, so
    /// a tuner can replay the exchange without re-running the app for every
    /// prompt it wants to try.
    static func dump(system: String, sentences: [String], scores: String) {
        guard let path = ProcessInfo.processInfo.environment["PARROTFLOW_JUDGE_DUMP"],
              !path.isEmpty
        else { return }
        var body = "SYSTEM " + escaped(system) + "\n"
        for (index, sentence) in sentences.enumerated() {
            body += "MENU \(letters[index % letters.count]). \(sentence)\n"
        }
        if !scores.isEmpty { body += "SCORES " + escaped(scores) + "\n" }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = body.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// One line per record, so a system message holding newlines cannot be
    /// read as the start of the next record.
    ///
    /// Newlines only, and backslashes left alone. `scripts/tune-judge.py`
    /// reverses this with one `replace("\\n", "\n")`, and escaping the
    /// backslash too would need the harness to learn a second rule for a
    /// character no prompt in this repository contains.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}
