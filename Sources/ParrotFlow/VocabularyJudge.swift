import Foundation

/// Takes one KEEP or REVERT per substitution the vocabulary pass made.
///
/// The pass matches spelling and sound, and cannot read the sentence, so it
/// writes names over ordinary words that happen to look or sound like one.
/// This is where that gets undone.
///
/// ## The shape, and why it changed
///
/// It used to build every reading the substitutions allowed and ask the model
/// to pick one by letter. That shape was chosen because one word can go two
/// ways in one sentence:
///
///     heard:  Mira and Mirza … deployed on Versailles … the Versailles castle
///     meant:  Mira and Mirza … deployed on Vercel     … the Versailles castle
///
/// A menu can say that. So can one verdict per change, and the verdict is the
/// smaller question.
///
/// **Measured on 74 substitutions from one speaker's own dictation**, three
/// replays, zero flips:
///
///     arm                                 all      name said   name not
///     one verdict per change              63/74    21/22       42/52
///     the lettered menu                   29/74    18/22       11/52
///     blind: every substitution stands    22/74    22/22       0/52
///     blind: every substitution goes      52/74    0/22        52/52
///
/// The two blind rows are the point — a mechanism that does not beat its own
/// blind version has not been shown to work. Head to head the verdict wins 36
/// and loses 2 against the menu, and 42 to 1 against leaving the substitutions
/// alone. On the 42 clips the wording was *not* chosen on it is 42/50 against
/// the menu's 20/50.
///
/// The menu's own record is why it went: four rounds and ten framings never
/// moved it off 0 of 8 on the clips where an ordinary word was overwritten,
/// because a menu asks the model to rank whole sentences and it answers by
/// agreeing with the first one.
///
/// The harness and the labelled clips are not in the tree — the numbers are
/// recorded in PR #102 and here. What is testable without them is: the parser
/// (`scripts/check-verdicts.sh`) and the prompt's own shape
/// (`scripts/check-judge-prompt.sh`).
///
/// The model still never writes the transcript. It answers KEEP or REVERT and
/// this file puts the words back, which is what stops it tidying the grammar
/// on the way past — a prompt asked to return the corrected sentence mangled
/// 15 of 58 inputs.
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
/// ## Why the prompt is not a file any more
///
/// It was a file the pipeline entry named and the user owned. Nobody should
/// own this one. It is not a matter of taste — a wording is right or wrong
/// against a measurement, five wordings of one sentence in the old prompt
/// scored 38, 39, 40, 41 and 42 on the same cases, and the shape the text has
/// to keep is decided by the parser below it.
///
/// So it is compiled in, and a config still naming a file is **refused**
/// rather than warned about. A warning leaves a filename in a config doing
/// nothing, and somebody who edits that file and sees the judge behave exactly
/// as before has no way to find out why.
enum VocabularyJudge {

    /// What the model is asked, minus the sentence.
    ///
    /// `Sage` is deliberately a name no real vocabulary here holds, so the
    /// example teaches the shape of the question rather than the answer for
    /// any particular term. Keep that property if the example changes.
    ///
    /// There is no paragraph about how clearly the recogniser heard each
    /// spelling. The old prompt had one, saying a gap over about 4 meant the
    /// sound could decide. The largest gap in the data is 2.72, and argmax on
    /// those numbers scores 28 of 57 spans against 34 for the constant "keep
    /// what the decoder wrote". It was describing a scale that does not exist.
    ///
    /// `{terms}` can carry `(person)` / `(place)` / `(organization)` after a
    /// name — see where the caller builds it, from `Config.Vocabulary.Term.kind`
    /// — with nothing here telling the model what that means. An earlier draft
    /// added a sentence explaining it and no worked example ever showed it in
    /// use, which is the shape this file elsewhere argues against. Give it a
    /// worked example before writing a sentence about it.
    static let prompt = """
        The user dictates text. A deterministic pass has already replaced some words
        with names from their vocabulary.

        That pass matches spelling only. It never hears the sentence. It fires on every
        occurrence of a spelling it knows, including the ones where the user meant the
        ordinary word.

        Below is the sentence as the recogniser wrote it, and the same sentence after
        the pass. For each replacement, say whether it should stand.

        A replacement stands when that name makes sense where it sits. Revert it when
        the original was the ordinary word and the name does not belong in that
        sentence.

        The names in their vocabulary are: {terms}. Anything else in the sentence is an
        ordinary word, however much it looks like one of them.

        Example.

          heard:   add a little sage to the sauce and let it rest
          after:   add a little Sage to the sauce and let it rest
          changed: 1. sage -> Sage

          The sentence is about cooking. An accounting system does not go in a sauce.
          1. REVERT

          heard:   the invoice is still sitting in sage
          after:   the invoice is still sitting in Sage
          changed: 1. sage -> Sage

          An invoice sitting in the accounting system is what the sentence is about.
          1. KEEP
        """

    /// The sentence to judge, as the model sees it.
    ///
    /// Split from `prompt` so the standing instructions can be cached as a
    /// system message while this changes every dictation.
    static func question(heard: String, after: String, changes: [Change]) -> String {
        let listed = changes.enumerated().map { index, change in
            let line = "\(index + 1). \(change.was) -> \(change.now)"
            return index == 0 ? line : String(repeating: " ", count: 11) + line
        }.joined(separator: "\n")
        return """
            Now this one.

              heard:   \(heard)
              after:   \(after)
              changed: \(listed)

            Answer with one line per change: its number, then KEEP or REVERT. Nothing else.
            """
    }

    /// How much of one sentence may be put to the model at once. Optional
    /// stage params, because they are the numbers a person tuning their own
    /// pipeline wants to move, and an environment variable is not something a
    /// config file can say.
    struct Caps: Equatable, Codable {
        /// Uncertain positions, not proposals. One rule can rewrite three
        /// words. Past this many the stage keeps what the decoder wrote and
        /// says so — a list nobody can read decides nothing.
        var slots = 4
        /// Readings per place, the decoder's own included.
        ///
        /// Two, and two is now the ceiling as well as the default: a verdict
        /// has two sides, so a third reading of one span cannot be expressed.
        /// It was 3 while the answer was a letter on a menu. A place that
        /// offers `Praisy` and `Praisy's` over "praise" loses the second of
        /// them here, which is the price of the shape.
        var perSlot = 2
        /// Places in one sentence that may be about the same term.
        ///
        /// `perSlot` bounds one place. Nothing bounded a term across places,
        /// and a term reaches the list from five directions at once — a
        /// `replacements` rule that already rewrote the text, a `heard:`
        /// rendering matched fuzzily, the rescorer's own proposal, the wider
        /// spans built around it, and the CTC spotter hearing it somewhere
        /// else entirely. On `17-39-40` that is six slots for three terms,
        /// which is past `slots` and declines the whole sentence.
        ///
        /// So the list grows with the size of the vocabulary rather than with
        /// how noisily one term fires. Two, because a name said twice in one
        /// sentence is ordinary and a name said three times is rare enough
        /// that the third mention is more often the spotter than the speaker.
        /// See `slots(in:from:caps:)` for which two survive.
        var perTerm = 2

        /// `max_readings:`, kept only so it can be refused by name.
        ///
        /// It capped a lettered menu. There is no menu, so the number would do
        /// nothing — and a number in a config file doing nothing is the
        /// failure this whole type's `problems` exists to prevent.
        var readings: Int?

        static let standard = Caps()

        /// Two readings a place, whatever was typed. A verdict has two sides.
        static let readingCeiling = 2

        /// What is wrong with these numbers, in the words `--check-config`
        /// uses. A cap of zero silences the stage on every transcript, which
        /// reads as the judge being broken rather than as a number being wrong.
        ///
        /// **Refused, not clamped.** A number quietly rounded down is a
        /// configuration that says one thing and does another, and the person
        /// who typed it learns nothing. Both cases below were found by review:
        /// `max_per_slot: 3` built a third reading that `changes(in:from:)`
        /// then dropped without a word, and `max_readings:` was read and
        /// ignored.
        var problems: [String] {
            var found: [String] = []
            for (name, value) in [
                ("max_slots", slots), ("max_per_slot", perSlot), ("max_per_term", perTerm),
            ] where value < 1 {
                found.append("vocabulary: \(name) is \(value) — it has to be at least 1")
            }
            if perSlot > Self.readingCeiling {
                found.append("vocabulary: max_per_slot is \(perSlot), and the judge answers"
                    + " KEEP or REVERT — \(Self.readingCeiling) is the most a place can"
                    + " offer. Anything past the second reading would be built and never"
                    + " shown")
            }
            if let readings {
                found.append("vocabulary: max_readings is \(readings) and nothing reads it."
                    + " It capped a lettered menu of whole sentences; the judge answers one"
                    + " change at a time now. Delete the line — `max_slots` is the cap that"
                    + " is left")
            }
            return found
        }
    }

    /// How well evidenced a reading is, best first.
    ///
    /// Only `perTerm` reads this, and only to decide which places survive when
    /// one term claims too many. It is a rank rather than a score because
    /// there is no number the five sources share: a rule has none at all, a
    /// wider span was never measured acoustically, and the spotter scores the
    /// term without scoring the word the decoder wrote.
    enum Standing: Int, Comparable {
        /// A `replacements` rule already rewrote the text here. Strongest, not
        /// because the rule is right but because it has already been acted on
        /// — dropping this slot is the one case where the speaker is left with
        /// a substitution and no way to refuse it.
        case rule = 0
        /// A `heard:` rendering one edit away from what the decoder wrote.
        /// Below a rule because nothing has acted on it yet, and above the
        /// acoustic sources because a spelling one edit from a rendering
        /// somebody wrote down is narrower evidence than a sound.
        case fuzzy = 1
        /// A rendering the words sound like. Beside `fuzzy` because it comes
        /// from the same place — a rendering somebody wrote down — and below
        /// it because a spelling one edit away is the narrower claim.
        case sound = 2
        /// The rescorer proposed it and both spellings were scored.
        case scored = 3
        /// A wider span built around one of the above. Nothing scored it.
        case wide = 4
        /// The spotter heard the term over these frames. Nothing scored the
        /// word the decoder wrote there, so there is no comparison — this is
        /// the source that fires on "went to the" and "deployed on".
        case spotted = 5

        static func < (a: Standing, b: Standing) -> Bool { a.rawValue < b.rawValue }
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
        /// The best-evidenced of the readings in it, for `Caps.perTerm`.
        let standing: Standing
    }

    /// One proposal reduced to what the question needs: a span, what stands
    /// there now, and the other reading of it.
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
        /// Where this reading came from, for `Caps.perTerm`.
        let standing: Standing
    }

    // MARK: - Gathering

    /// The proposals the pass left undecided, as places to ask about.
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
        // Which of the three acoustic sources made a proposal, read off its
        // scores rather than carried as a flag. `Vocabulary.apply` already
        // says the same thing there: the rescorer scores both spellings, a
        // wider span is scored by neither, and a spotter hit scores only the
        // term (F6 — absent means absent, so absence is readable).
        func standing(_ proposal: Vocabulary.Proposal) -> Standing {
            if proposal.heardScore != nil, proposal.termScore != nil { return .scored }
            return proposal.termScore == nil ? .wide : .spotted
        }
        for proposal in wanted {
            // Offsets rather than the index itself. A `String.Index` belongs to
            // the string it was made from, and `text` is a different string
            // once any stage above has touched it (F13).
            let was = pass.distance(from: pass.startIndex, to: proposal.range.lowerBound)
            let span = "\(was)\u{0}\(proposal.heard)"
            if let already = resolved[span] {
                parts.append(Part(
                    range: already, decoded: proposal.heard,
                    other: proposal.term, term: proposal.canonicalTerm,
                    standing: standing(proposal)
                ))
                continue
            }
            var range = Self.at(offset: was, holding: proposal.heard, in: text)
            if range == nil {
                // The text moved under the proposal. Re-anchored to the nearest
                // occurrence of the same words rather than to the *n*th one: a
                // counter labelled the second `Versailles` in one sentence as
                // the first, so the judge rewrote the castle and left the
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
                other: proposal.term, term: proposal.canonicalTerm,
                standing: standing(proposal)
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
    /// first, in the place the model agrees with most readily. So
    /// "deployed on Vercel and the Versailles castle" would be offered
    /// "deployed on Versailles" as the decoder's own reading, which it never
    /// was.
    ///
    /// `before` is the transcript `replacements` was handed, and it says which
    /// occurrence is which. A rule rewrites in place and reorders nothing, so
    /// the terms standing in the text now are, in order, the occurrences of the
    /// rule sources and of `term` in `before` — and only the first kind is a
    /// substitution to offer back. See `rewritten(_:_:in:became:)`.
    ///
    /// **The pairs are read per term, not one at a time.** Two rules can write
    /// the same term in one sentence: `Versal -> Vercel; Versailles -> Vercel`
    /// for "deployed on Vercel against the Versailles Castle". A pair counted on
    /// its own accounts for one of the two `Vercel`s standing, so it fails its
    /// count and takes its reading down with it, and nothing is asked.
    /// Counted together the two pairs account for both occurrences, and each one
    /// is offered its own spelling back.
    ///
    /// When the counts still do not line up, something else wrote the term as
    /// well — a pattern rule, or a rule whose target contains it — and nothing
    /// here can say which occurrence came from where. Then none of them are
    /// offered, and the log says so.
    ///
    /// A rule whose source is a pattern is skipped. `/(\w+) dot (\w+)/` names
    /// no spelling to offer back, and showing the model a pattern would ask
    /// it to judge a regular expression. It still wrote the term, so the
    /// count above is what stops the literal rules beside it from claiming its
    /// occurrence.
    static func ruleParts(_ changes: String, in text: String, before: String?) -> [Part] {
        // Grouped before anything is counted, because the count is per term and
        // not per pair. First-seen order is kept so the parts still come out in
        // the order the rules are reported in. The key is lowercased because
        // `spans` finds the term that way — two pairs naming it in different
        // case are one term here, as they are in the text.
        var order: [String] = []
        var sources: [String: [String]] = [:]
        var spelled: [String: String] = [:]
        for pair in changes.split(separator: ";") {
            let pairText = pair.split(separator: "@").first.map(String.init) ?? String(pair)
            guard let arrow = pairText.range(of: "->") else { continue }
            let heard = pairText[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let term = pairText[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, !term.isEmpty, heard != term,
                  !heard.hasPrefix("/"), !term.contains("$")
            else { continue }
            let key = term.lowercased()
            if sources[key] == nil {
                order.append(key)
                spelled[key] = term
            }
            sources[key, default: []].append(heard)
        }

        var parts: [Part] = []
        for key in order {
            guard let term = spelled[key], let heard = sources[key] else { continue }
            let stands = Vocabulary.spans(of: term, in: text, ignoringCase: true)
            guard let before else {
                // No earlier text to compare against. `replacements` publishes
                // it whenever that stage ran, so this is now only a pipeline
                // with a `vocabulary:` stage and no `replacements` above it —
                // where a rule pair can still arrive from a scope seeded
                // elsewhere. It used to be every path with no audio, and that
                // cost the judge a reading under `vocabulary.acoustic: false`.
                // One occurrence is still decidable without it: the rule is in
                // `changes`, so it fired at least once, and a pre-existing term
                // would be a second occurrence. More than one and nothing here
                // can say which, so none are offered. Grouping does not help
                // here — with no earlier text there is nothing to line the
                // occurrences up against.
                if stands.count == 1 {
                    for source in heard {
                        parts.append(Part(
                            range: stands[0], decoded: source, other: source, term: term,
                            standing: .rule
                        ))
                    }
                } else if stands.count > 1 {
                    for source in heard {
                        Log.write("vocabulary judge: \"\(term)\" stands \(stands.count) time(s)"
                            + " and no acoustic pass ran, so which one \"\(source)\" became"
                            + " cannot be told; that reading is not offered")
                    }
                }
                continue
            }
            guard let mine = rewritten(heard, term, in: before, became: stands.count) else {
                Log.write("vocabulary judge: \"\(term)\" stands \(stands.count) time(s) and"
                    + " the transcript before the rules cannot account for that many;"
                    + " not offering \(heard.map { "\"\($0)\"" }.joined(separator: ", ")) back")
                continue
            }
            for (index, source) in mine.enumerated() {
                guard let source else { continue }
                parts.append(Part(
                    range: stands[index], decoded: source, other: source, term: term,
                    standing: .rule
                ))
            }
        }
        return parts
    }

    /// Which of the terms standing in the text now were written by a rule, and
    /// by which one.
    ///
    /// Each rule turns its own source into `term` and leaves every `term` where
    /// it was. Rules rewrite in place, so the order is preserved: the *i*-th
    /// term in the text now is the *i*-th of those occurrences in the text
    /// before. The ones that were a rule source are the substitutions; the rest
    /// were already right and must not be offered a reading the decoder never
    /// produced.
    ///
    /// **Every rule that wrote this term is counted at once.** One at a time,
    /// two rules writing one term each account for a single occurrence, both
    /// fail the count, and the sentence is not judged at all.
    ///
    /// Nil when the counts disagree, which means something other than these
    /// rules also wrote the term. Guessing there is how a correct word gets a
    /// wrong spelling offered as what the decoder wrote.
    ///
    /// Nil as well when two of the marks overlap. Only one rule can have fired
    /// on a given span, so a count that lines up across an overlap lined up by
    /// accident, and matching the marks to the occurrences by position past that
    /// point would hand a reading to a span it does not own.
    ///
    /// - Returns: one entry per term standing in the text now, in order — the
    ///   rule source that wrote it, or nil where the decoder wrote it itself.
    static func rewritten(
        _ heard: [String], _ term: String, in before: String, became stands: Int
    ) -> [String?]? {
        var marks: [(at: Range<String.Index>, rule: String?)] =
            Vocabulary.spans(of: term, in: before, ignoringCase: true).map { ($0, nil) }
        for source in heard {
            marks += Vocabulary.spans(of: source, in: before, ignoringCase: true)
                .map { ($0, source) }
        }
        marks.sort { $0.at.lowerBound < $1.at.lowerBound }
        guard marks.count == stands else { return nil }
        guard !marks.indices.dropFirst().contains(where: {
            marks[$0].at.lowerBound < marks[$0 - 1].at.upperBound
        }) else { return nil }
        return marks.map(\.rule)
    }

    // MARK: - Slots and readings

    /// The places one term may claim, cut to `limit`, best evidenced first.
    ///
    /// The order the survivors are chosen in is the point. A term arrives from
    /// five sources at once and they are not equally worth a line, so the
    /// cut is by `Standing` first and by position second — earliest wins a tie,
    /// because a reader meets the leftmost place first and because the spotter's
    /// spans, which are the ones this mostly cuts, arrive sorted by score and
    /// not by where they sit.
    ///
    /// Measured on `17-39-40`, six slots for three terms: `Vercel` claims the
    /// two places a rule rewrote plus "universal", and "universal" is the one
    /// that goes. What survives is returned in the order it arrived in, so the
    /// list still reads left to right.
    ///
    /// A slot naming several terms is charged to all of them and kept while
    /// **any** of them has room. Refusing it because one term is full would drop
    /// a place that is still a live question about another.
    ///
    /// Applied to finished slots, not to the groups they are built from. A group
    /// whose readings all collapse to the decoder's own is not a question and is
    /// dropped anyway — letting it spend a term's budget on the way out would
    /// cost a real place for nothing.
    private static func capped(_ slots: [Slot], in text: String, to limit: Int) -> [Slot] {
        guard limit >= 1, !slots.isEmpty else { return slots }
        let ranked = slots.indices.sorted { left, right in
            if slots[left].standing != slots[right].standing {
                return slots[left].standing < slots[right].standing
            }
            return slots[left].range.lowerBound < slots[right].range.lowerBound
        }
        var used: [String: Int] = [:]
        var keep = Set<Int>()
        for index in ranked {
            let slot = slots[index]
            guard slot.terms.contains(where: { used[$0, default: 0] < limit }) else {
                Log.write("vocabulary judge: \"\(text[slot.range])\" is a"
                    + " \(slot.terms.joined(separator: "/")) reading past max_per_term"
                    + " \(limit); not offered")
                continue
            }
            for term in slot.terms { used[term, default: 0] += 1 }
            keep.insert(index)
        }
        return slots.indices.filter(keep.contains).map { slots[$0] }
    }

    /// Every position still in question, left to right, as one slot each.
    ///
    /// Overlapping spans used to be dropped, earliest wins. That was right when
    /// they were competing substitutions and wrong now they are readings of the
    /// same words: `Praisy` decoded as "praise he" arrives as both "praise" and
    /// "praise he", and dropping one leaves a question where every answer strands a
    /// word. So they are grouped, and the slot covers the widest of them.
    ///
    /// A slot with one reading is not a question, so it is left out.
    ///
    /// `caps.perTerm` is applied to the slots rather than to the parts. Two
    /// readings of one span — `Praisy` and `Praisy's` over "praise" — are one
    /// place, not two, and counting them separately would spend the budget on
    /// the case this stage exists for.
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
                terms: Array(Set(group.parts.map(\.term))).sorted(),
                standing: group.parts.map(\.standing).min() ?? .spotted
            ))
        }
        return capped(built, in: text, to: caps.perTerm)
    }

    // MARK: - Fuzzy renderings

    /// How far from a `heard:` rendering a word may sit and still match it.
    ///
    /// One edit, and never onto a word the spell checker recognises. Both
    /// halves are measured, over 58,265 tokens of this speaker's own dictation
    /// — every word and every two-word window in 2,000-odd clips — against the
    /// 37 renderings in their vocabulary:
    ///
    ///     edits  rendering  spell-check  words newly  fires   fires on an
    ///            length     gate         matched              ordinary word
    ///     1      any        no           43           200     139
    ///     1      any        yes          27           61      0
    ///     1      6+         yes          13           23      0
    ///     2      any        yes          88           209     0
    ///
    /// **The gate is what makes one edit safe, and a length floor is not.**
    /// `Praises` is a rendering of `Praisy` and is one edit from the ordinary
    /// word "praise", which this speaker says 111 times in the archive. No
    /// floor separates those — the rendering is seven characters and the word
    /// is six. Without the gate, 139 of the 200 fires land on a word somebody
    /// meant. With it, none of them do.
    ///
    /// **Two edits is dead.** With the gate it is still 209 fires against 61,
    /// and every extra one is a longer reach for the same evidence. Without
    /// the gate it writes `Claude` over "but" 123 times.
    ///
    /// **A length floor buys nothing on top of the gate and costs real
    /// matches.** At six characters the gate is already at zero and the fires
    /// drop from 61 to 23: `RXV` can no longer reach "RX" or "Rx V", which are
    /// 22 of them and every one a real garbling of `Arexvy`.
    ///
    /// **What it still costs.** Five of the 61 are "praised", which the word
    /// list this was measured against does not hold because it is inflected.
    /// `NSSpellChecker` is a better dictionary than that file, so the shipped
    /// gate should catch it; the measured number is the pessimistic one.
    ///
    /// Nothing here writes a word on its own. A match becomes a change the
    /// model votes on, which is the second reason it is safe to be this loose:
    /// the looser half of the mechanism sits behind the judge.
    static let fuzzyEdits = 1

    /// Whether the two spellings differ only in apostrophes.
    ///
    /// The other half of `fuzzy`, and the half that motivated it. `Praisy`'s
    /// list holds `Praises`, the decoder wrote `Praise's`, `\bPraises\b` does
    /// not match an apostrophe, and the name was lost — measured, on live
    /// dictation, as the whole cost of `acoustic: false`.
    ///
    /// **Not an edit-distance match, and not gated on the dictionary.** The
    /// word *is* the rendering; it is written with a mark that is not a
    /// letter. The gate would refuse it, because `Praise's` is a real
    /// possessive of a real word — which is exactly why no dictionary can
    /// settle this one and the sentence has to.
    ///
    /// Measured over the same 58,265 tokens: **one** word matches this way,
    /// six times, and it is `Praise's`. There is no false-fire budget being
    /// spent here.
    static func apostrophesApart(_ a: String, _ b: String) -> Bool {
        let strip = { (text: String) in
            text.lowercased().filter { $0 != "'" && $0 != "\u{2019}" }
        }
        return a.lowercased() != b.lowercased() && strip(a) == strip(b)
    }

    /// Words a `heard:` rendering matches without an exact rule reaching them.
    ///
    /// Two ways in, and they are not the same mechanism. A word spelled like a
    /// rendering but for its apostrophes is that rendering — see
    /// `apostrophesApart`. Anything else has to be one edit away *and* be a
    /// word no dictionary knows, which is what keeps this off the ordinary
    /// words it would otherwise land on — see `fuzzyEdits`.
    ///
    /// Only the spans no rule reached. An exact rule has already fired on the
    /// spellings it knows, and a span another part already claims is not put
    /// on the list twice.
    ///
    /// Nothing is written here. Each match becomes one more change for the
    /// model to vote on.
    ///
    /// - Parameter rules: the vocabulary's rules — `Config.vocabularyRules`.
    ///   Not `transcription.rules`: those are a table somebody wrote for
    ///   themselves, and widening them by an edit is a different decision from
    ///   widening a rendering the app learnt. A pattern rule names no spelling
    ///   to be near, and a deletion names no term, so both are skipped here
    ///   whatever is passed.
    static func fuzzyParts(
        in text: String, rules: [Config.Transcription.Rule], claimed: [Part]
    ) -> [Part] {
        let renderings = rules.filter { !$0.isRegex && !$0.isDeletion && !$0.source.isEmpty }
        guard !renderings.isEmpty else { return [] }
        let widest = max(1, renderings.map { $0.source.split(separator: " ").count }.max() ?? 1)

        var found: [Part] = []
        var taken = claimed.map(\.range)
        let words = Replacements.wordRanges(in: text)
        for start in words.indices {
            // Widest window first. `red rock` should claim its span before a
            // one-word rendering inside it does, and the check below is what
            // stops the narrower one being offered afterwards.
            for count in stride(from: widest, through: 1, by: -1)
            where start + count <= words.count {
                let span = words[start].lowerBound..<words[start + count - 1].upperBound
                let word = String(text[span])
                // A span another part owns is already a question. Overlapping
                // rather than equal: a two-word window covering a claimed word
                // would put the same place on the list a second time.
                if taken.contains(where: {
                    $0.lowerBound < span.upperBound && span.lowerBound < $0.upperBound
                }) { continue }
                // Asked once per span and only when something is close enough
                // to need it. The spell service times out, and a timeout is
                // indistinguishable from a known word
                // (`Replacements.isRealWord`) — which falls the safe way here
                // as it does there: the span is left alone and a name is not
                // corrected, rather than an ordinary word being written over.
                var ordinary: Bool?
                for rule in renderings
                where rule.source.split(separator: " ").count == count {
                    // An exact match is the rule's own job, and a word that is
                    // already the term is not a substitution.
                    if word.compare(rule.source, options: .caseInsensitive) == .orderedSame
                        || word.compare(rule.replacement, options: .caseInsensitive)
                            == .orderedSame {
                        continue
                    }
                    if !apostrophesApart(word, rule.source) {
                        guard within(fuzzyEdits, word, rule.source) else { continue }
                        if ordinary == nil {
                            ordinary = word.split(separator: " ").allSatisfy {
                                Replacements.isRealWord(String($0))
                            }
                        }
                        guard ordinary == false else { continue }
                    }
                    found.append(Part(
                        range: span, decoded: word,
                        other: Vocabulary.inflected(rule.replacement, like: word),
                        term: rule.replacement, standing: .fuzzy
                    ))
                    taken.append(span)
                    break
                }
            }
        }
        return found
    }

    /// Windows of the transcript that *sound* like a term, whatever they are
    /// spelled like.
    ///
    /// The one thing letters cannot do. `geler` is 0.60 from `Gelar` by
    /// spelling and identical to it by sound; so are `Ghost E`/`Ghostty`,
    /// `Jemma`/`Gemma`, `eye brands`/`Ibrance`, `Prazi`/`Praisy`. Every one of
    /// those is a name this speaker lost, and no edit distance reaches them.
    ///
    /// **The floor is 0.85 and it was measured, not chosen.** Over 20891 real
    /// dictations, scoring every 1- and 2-word window against every term and
    /// every rendering:
    ///
    ///     floor   fires   per clip   distinct windows
    ///     0.70    11659     0.56
    ///     0.75     8262     0.40
    ///     0.80      826     0.04
    ///     0.85      147     0.007            41
    ///
    /// The cliff between 0.80 and 0.85 is two-word windows of ordinary words —
    /// `and me` and `and see` reach `Andrey` at 0.80, 312 times between them.
    /// Above it, 41 windows in the whole archive and 33 of them are a name
    /// this speaker actually lost. Below it the list is 6011 copies of
    /// `praise`, which sounds like `Praisy` because it is a homophone; that
    /// one is not a floor's to settle and never was.
    ///
    /// **No dictionary gate, unlike `fuzzyParts`.** That gate refuses any
    /// window a spell checker knows, which is right where a match may be
    /// written in and wrong here: the words this fires on are `pressed`,
    /// `phrases`, `geler`, `pretty` — ordinary words, every one, and the
    /// ordinary ones are the whole point. Nothing is written. Each match is
    /// one more reading for the model to vote on, and the floor is what pays
    /// for that.
    ///
    /// English only, by the caller. espeak's `en-us` letter-to-sound over a
    /// French transcript answers, and the answer is noise.
    ///
    /// - Parameter sounds: `Config.vocabularySounds` — every term and every
    ///   rendering, with the IPA the file writes down for it. A rendering with
    ///   no `phonemes:` is sounded out from its spelling, which is right
    ///   whenever the spelling is a word: espeak reads `Preci` as /pɹɛsaɪ/ and
    ///   that entry needs its sound written down or it reaches nothing.
    static func phonemeParts(
        in text: String,
        sounds: [(term: String, form: String, phonemes: String?)],
        voice: String, floor: Float, claimed: [Part]
    ) -> [Part] {
        guard !sounds.isEmpty, Phonemes.binary != nil else { return [] }
        // Two words at least, whatever the vocabulary is spelled like. A sound
        // has no spaces in it — `parrot flow` and `ParrotFlow` are both
        // /pæɹətfloʊ/, and so are `cloud card` and `Cloudcard` — so a window
        // has to be able to be wider than any single term is written.
        let widest = max(2, sounds.map { $0.form.split(separator: " ").count }.max() ?? 1)

        // Every span worth asking about, gathered before espeak is called
        // once. Starting the process costs more than running it, so the
        // dictation asks in one go or the stage is not worth having.
        let words = Replacements.wordRanges(in: text)
        var taken = claimed.map(\.range)
        var windows: [(span: Range<String.Index>, text: String, width: Int)] = []
        for start in words.indices {
            for count in stride(from: widest, through: 1, by: -1)
            where start + count <= words.count {
                let span = words[start].lowerBound..<words[start + count - 1].upperBound
                windows.append((span, String(text[span]), count))
            }
        }
        // What the terms are already spelled as. A window that *is* the term,
        // or is a rendering an exact rule has already fired on, is not a
        // question.
        let spelled = Set(sounds.flatMap { [$0.term.lowercased(), $0.form.lowercased()] })

        var said = Phonemes.of(
            windows.map(\.text) + sounds.filter { $0.phonemes == nil }.map(\.form),
            voice: voice
        )
        for entry in sounds where entry.phonemes != nil {
            said[entry.form] = entry.phonemes
        }
        // Widest first, so `parrot flow` claims its span before `flow` can.
        // The overlap check below is what stops the narrower one afterwards.
        var found: [Part] = []
        for window in windows.sorted(by: { $0.width > $1.width || ($0.width == $1.width && $0.span.lowerBound < $1.span.lowerBound) }) {
            guard !spelled.contains(window.text.lowercased()),
                  let heard = said[window.text], !heard.isEmpty else { continue }
            if taken.contains(where: {
                $0.lowerBound < window.span.upperBound && window.span.lowerBound < $0.upperBound
            }) { continue }

            // Every form, whatever its width. `fuzzyParts` compares a window
            // only with renderings of the same word count, because it compares
            // spellings and a space is a letter's worth of difference. Here it
            // is not: the space is where the decoder guessed a word boundary,
            // and guessing it wrong is the mistake being caught.
            var best: (score: Float, term: String)?
            for entry in sounds {
                guard let form = said[entry.form], !form.isEmpty else { continue }
                // The length ratio caps the score on its own, so a pair that
                // cannot reach the floor even aligned perfectly is skipped
                // before the distance is computed.
                let ratio = Float(min(heard.count, form.count)) / Float(max(heard.count, form.count))
                guard sqrt(ratio) >= floor else { continue }
                let score = Phonemes.similarity(heard, form)
                guard score >= floor, score > (best?.score ?? 0) else { continue }
                best = (score, entry.term)
            }
            guard let best else { continue }
            found.append(Part(
                range: window.span, decoded: window.text,
                other: Vocabulary.inflected(best.term, like: window.text),
                term: best.term, standing: .sound
            ))
            taken.append(window.span)
            if ProcessInfo.processInfo.environment["PARROTFLOW_JUDGE_DUMP"] != nil {
                Log.write(String(format: "  sound \"%@\" /%@/ -> %@ %.2f",
                                 window.text, heard, best.term, best.score))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Whether two strings are `cap` edits apart or fewer, case ignored.
    ///
    /// Plain Levenshtein, given up as soon as it passes the cap — which is
    /// what the table above was measured with. `VoiceCommand.similarity` is
    /// the app's other distance and is not this one: it discounts confusable
    /// letters and returns a ratio, so a threshold on it does not mean "one
    /// edit" at any length.
    static func within(_ cap: Int, _ a: String, _ b: String) -> Bool {
        let left = Array(a.lowercased()), right = Array(b.lowercased())
        guard abs(left.count - right.count) <= cap else { return false }
        var previous = Array(0...right.count)
        for (index, character) in left.enumerated() {
            var row = [index + 1]
            for (column, other) in right.enumerated() {
                row.append(min(previous[column + 1] + 1, row[column] + 1,
                               previous[column] + (character == other ? 0 : 1)))
            }
            guard let best = row.min(), best <= cap else { return false }
            previous = row
        }
        return previous[right.count] <= cap
    }

    // MARK: - Changes and verdicts

    /// One place the pass changed: what the decoder wrote, and what stands
    /// there instead.
    struct Change {
        let range: Range<String.Index>
        /// What the decoder wrote over this span.
        let was: String
        /// The reading the pass wants there — the term, inflected as the span
        /// needs it.
        let now: String
        /// The vocabulary terms this place is about, for `{terms}`.
        let terms: [String]
        /// Where the reading came from, carried through from the slot. Read by
        /// `settle`, which gates one source and not the others.
        let standing: Standing
    }

    /// The substitutions to put to the model, left to right.
    ///
    /// A slot offers the decoder's own reading first and the term's second, so
    /// a change is just those two. A slot with no second reading is not a
    /// question and does not appear.
    ///
    /// **A place the pass only proposed is a change too.** The acoustic pass
    /// hands over spans it has not written, and the text still holds the
    /// decoder's word there. The question is the same one either way — does
    /// this name belong here — so the sentence shown as `after` is the one
    /// where every change has been taken, whether the pass took it or not.
    /// That is also how it was measured.
    ///
    /// Left to right and never overlapping, checked here rather than assumed.
    /// `sentences` and `applying` walk the list with one cursor, so a range
    /// that starts before the previous one ended would slice the string
    /// backwards and **trap** — losing the whole dictation, not one name.
    /// `slots` merges overlaps already; this is what keeps that a local
    /// property of `slots` instead of a rule every future caller has to know.
    static func changes(in text: String, from slots: [Slot]) -> [Change] {
        var built: [Change] = []
        for slot in slots.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard slot.options.count > 1, slot.options[0] != slot.options[1] else { continue }
            if let last = built.last, slot.range.lowerBound < last.range.upperBound {
                Log.write("vocabulary judge: \"\(text[slot.range])\" overlaps the place"
                    + " before it; not offered")
                continue
            }
            built.append(Change(range: slot.range, was: slot.options[0],
                                now: slot.options[1], terms: slot.terms,
                                standing: slot.standing))
        }
        return built
    }

    /// The changes a spelling lesson settles, so no model is asked about them.
    ///
    /// "urza spells mirza" teaches a mapping. The word before `spells` is the
    /// source, and writing the term over it destroys the lesson — "Mirza spells
    /// mirza" teaches nothing. `true` means revert it.
    ///
    /// Matched on the word after the span, not on the activation phrase. That
    /// phrase is itself mangled in the archive — "Hey Barrot", "by the way
    /// pirate" — so `spells` is the only reliable tell.
    ///
    /// **Measured on the four cases in `tests/judge-cases.yaml`**: the rule is
    /// 4/4, and `gemma4:e4b-mlx` and `gemma3:4b` are both 0/4, each answering
    /// KEEP to all of them. The sentence looks exactly like the one where a
    /// name was misheard, so a model reading it has nothing to go on. Prose
    /// telling it about the pattern was in `prompt` and did not fix them.
    ///
    /// The honest false positive is a sentence really about spelling — "Vercel
    /// spells its name oddly" — which loses its substitution. Nothing in the
    /// archive does that, and the cost is one name left as the decoder wrote
    /// it, which is where every other failure in this stage lands.
    static func teaching(in text: String, changes: [Change]) -> [Bool] {
        changes.map { change in
            var cursor = change.range.upperBound
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            var next = ""
            while cursor < text.endIndex, text[cursor].isLetter {
                next.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            return next.compare("spells", options: .caseInsensitive) == .orderedSame
        }
    }

    /// The sentence with every change taken, and the one with none of them.
    ///
    /// Both are built here rather than read off the transcript because the
    /// transcript is neither: a rule has already rewritten its span and the
    /// acoustic pass has not rewritten its own.
    static func sentences(
        in text: String, from changes: [Change]
    ) -> (heard: String, after: String) {
        var heard = "", after = "", cursor = text.startIndex
        for change in changes {
            heard += text[cursor..<change.range.lowerBound] + change.was
            after += text[cursor..<change.range.lowerBound] + change.now
            cursor = change.range.upperBound
        }
        return (heard + text[cursor...], after + text[cursor...])
    }

    /// The transcript the verdicts ask for.
    ///
    /// `true` keeps the substitution, `false` puts the decoder's word back. A
    /// verdict list shorter than the changes keeps the rest, which is the same
    /// direction every other failure in this stage falls: what arrived is what
    /// ships.
    static func applying(
        _ verdicts: [Bool], to text: String, changes: [Change]
    ) -> String {
        var out = "", cursor = text.startIndex
        for (index, change) in changes.enumerated() {
            let keep = index < verdicts.count ? verdicts[index] : true
            out += text[cursor..<change.range.lowerBound] + (keep ? change.now : change.was)
            cursor = change.range.upperBound
        }
        return out + text[cursor...]
    }

    /// Text with each span written the way it was settled, and every span
    /// nothing settled left exactly as `text` already has it.
    ///
    /// Three outcomes where `applying` has two, and the third is the one that
    /// matters when no model ran: `nil` writes neither reading, it copies what
    /// is there. A rule substitution is already in the text, so copying keeps
    /// it; a sound proposal is not, so copying leaves the decoder's word. Both
    /// are "what arrived ships", which is this stage's contract on every path
    /// where something went wrong.
    ///
    /// `reverting(taught:)` is this with `true` unreachable.
    static func settling(_ decided: [Bool?], in text: String, changes: [Change]) -> String {
        var out = "", cursor = text.startIndex
        for (index, change) in changes.enumerated() {
            out += text[cursor..<change.range.lowerBound]
            switch index < decided.count ? decided[index] : nil {
            case .some(true):  out += change.now
            case .some(false): out += change.was
            case .none:        out += String(text[change.range])
            }
            cursor = change.range.upperBound
        }
        return out + text[cursor...]
    }

    /// Text with every taught span put back to what the decoder wrote, and
    /// every other span left exactly as `text` already has it.
    ///
    /// Unlike `applying`, a change that is not being reverted is not
    /// rewritten to `now` — the model may never have run, so there is no
    /// verdict to write it from. This is what a spelling lesson mixed with an
    /// ordinary substitution needs when the model is disabled or unreachable:
    /// the lesson still gets undone, the ordinary change is left untouched.
    static func reverting(_ taught: [Bool], in text: String, changes: [Change]) -> String {
        var out = "", cursor = text.startIndex
        for (index, change) in changes.enumerated() {
            out += text[cursor..<change.range.lowerBound]
            out += (index < taught.count && taught[index]) ? change.was : String(text[change.range])
            cursor = change.range.upperBound
        }
        return out + text[cursor...]
    }

    /// How far a source may be settled without a model.
    enum Gating {
        /// The two word lists, and nothing else. They can only say "keep what
        /// is written there", so a source gated this way is never refused and
        /// never has a name written over it that was not already there.
        case lists
        /// The lists, then the two questions `SlotGate` asks. This one can
        /// write a name the text did not have, and can refuse a reading
        /// outright.
        case full
    }

    /// The verdicts the gates settle, so no model is asked about them.
    ///
    /// One entry per change. `true` writes the term, `false` writes back what
    /// the decoder wrote, `nil` is a question for the model. Exactly the shape
    /// `applying` already takes, and exactly what `taught` already does for a
    /// spelling lesson — this is the same idea with four more rules in it.
    ///
    /// The rules, in the order they are asked, which is the order they were
    /// measured in:
    ///
    /// 1. **The two word lists.** A word neither `NSSpellChecker` nor the
    ///    tokenizer's vocabulary has ever seen is not a word the speaker meant.
    ///    Write the term. Free, no model, and the only rule here that is
    ///    absolute rather than relative to the sentence.
    /// 2. **Can a name stand in that spot?** Mask the span, take the ten words
    ///    the model would put there, tag them. A spot that wants a verb, an
    ///    adverb or a preposition cannot hold a name, so the reading is
    ///    impossible and there is nothing to ask. Refuse it.
    /// 3. **Is that the spot the sentence reads worst?** The span must be both
    ///    the least expected word and inside the least expected pair. Write the
    ///    term. Anything else goes to the model.
    ///
    /// Measured at 47/50 with 21 model calls instead of 50 and no error either
    /// way — on `tests/judge-cases.yaml`, with no audio in it. See
    /// `Vocabulary.autoApplies(heard:term:)` for why that matters.
    ///
    /// **What each source may be settled by is not the same.** A rule
    /// substitution is already written into the text, so keeping one costs
    /// nothing and refusing one leaves the speaker with a rewrite they were
    /// never offered a way back from. Rules therefore get `.lists` — the two
    /// word lists, and only in the direction that keeps what is already there.
    /// The sound path writes nothing until somebody says so, so it gets
    /// `.full`.
    ///
    /// This is what settles `Versal -> Vercel` without a model. `Versal` is in
    /// neither list, so the rule that wrote it is right and there is nothing to
    /// ask. `Versailles -> Vercel` fires the same rule in the same sentence and
    /// is *not* settled: the spell checker knows the word, the lists say
    /// nothing, and it goes to the judge — which is where it belongs, and where
    /// the judge got it right. Under `.full` the rank would have ranked
    /// `Versailles` first of fifteen and written `Vercel Castle`.
    ///
    /// Rule 3 is the weak one and it is on by `rank`. It asks whether a word is
    /// *unexpected*, not whether it is *wrong*, and a rare proper noun is both
    /// unexpected and correct: on "visiting the Versailles Castle" it ranks
    /// `Versailles` first of fifteen and would write `Vercel Castle`. Rules 1
    /// and 2 have no such confound.
    static func settle(
        _ changes: [Change], in text: String, by policy: [Standing: Gating],
        gate: SlotGate?, rank: Bool
    ) -> [Bool?] {
        changes.map { change -> Bool? in
            guard let allowed = policy[change.standing] else { return nil }
            let term = change.terms.first ?? change.now
            if Vocabulary.autoApplies(heard: change.was, term: term) {
                Log.write("vocabulary gate: \"\(change.was)\" -> \"\(change.now)\""
                    + " is in neither word list — written, not asked")
                return true
            }
            guard allowed == .full, let gate else { return nil }
            guard let reading = try? gate.read(in: text, at: change.range) else { return nil }
            switch reading.route {
            case .decline:
                Log.write("vocabulary gate: \"\(change.was)\" -> \"\(change.now)\""
                    + " — the spot wants \(reading.tag), which cannot hold a name; refused")
                return false
            case .apply:
                // The rank is the half that can be wrong in silence, so it is
                // the half with a switch.
                guard rank else { return nil }
                Log.write("vocabulary gate: \"\(change.was)\" -> \"\(change.now)\""
                    + " is the worst-reading spot of its sentence"
                    + (reading.rank.map { " (rank \($0) of \(reading.windows))" } ?? "")
                    + " — written, not asked")
                return true
            case .judge:
                return nil
            }
        }
    }

    /// One verdict per change, read off the reply. `true` is KEEP.
    ///
    /// A number, then the word. Read loosely because a model that answers
    /// "1) KEEP" or "1 - revert" has decided and formatted it badly, and
    /// refusing that is refusing a correct answer.
    ///
    /// **A change the reply never names keeps its substitution.** That is the
    /// same default a reply nobody can read gets, and it is the direction that
    /// costs least: keeping leaves the transcript as it arrived, and this
    /// stage's whole contract is that what arrived is what ships when anything
    /// goes wrong.
    ///
    /// **A bare KEEP or REVERT with no number answers a one-change sentence.**
    /// Most sentences have one change and the model often drops the numbering
    /// for them. Past one change an unnumbered word is ignored, because
    /// spreading it over every change would let one word undo a name the
    /// model never spoke about.
    static func verdicts(_ reply: String, count: Int) -> [Bool] {
        guard count > 0 else { return [] }
        var read = [Bool?](repeating: nil, count: count)
        let upper = reply.uppercased()
        var scanner = upper.startIndex
        var number: Int?
        while scanner < upper.endIndex {
            let character = upper[scanner]
            if character.isNumber {
                var digits = ""
                while scanner < upper.endIndex, upper[scanner].isNumber {
                    digits.append(upper[scanner])
                    scanner = upper.index(after: scanner)
                }
                // A run of digits too long to be an `Int` is not a change
                // number; zero names none, so the word after it is dropped
                // rather than read as the answer to change one.
                number = Int(digits) ?? 0
                continue
            }
            if character.isLetter {
                var word = ""
                while scanner < upper.endIndex, upper[scanner].isLetter {
                    word.append(upper[scanner])
                    scanner = upper.index(after: scanner)
                }
                if word == "KEEP" || word == "REVERT" {
                    // No number in front and one change to answer about: the
                    // word is the answer. Otherwise it needs to say which.
                    let at = (number ?? (count == 1 ? 1 : 0)) - 1
                    if at >= 0, at < count, read[at] == nil { read[at] = word == "KEEP" }
                }
                number = nil
                continue
            }
            scanner = upper.index(after: scanner)
        }
        return read.map { $0 ?? true }
    }

    /// The exchange, appended to `PARROTFLOW_JUDGE_DUMP`.
    ///
    /// A harness wants to replay a dictation against another wording without
    /// re-running the app for every prompt it wants to try, and it wants to
    /// know whether the change list was right before blaming the answer. Two
    /// failures wear the same face in a transcript — a change list that missed
    /// the substitution, and a judge that kept the wrong one — and only the
    /// first is worth widening the proposals for.
    static func dump(system: String, user: String) {
        guard let path = ProcessInfo.processInfo.environment["PARROTFLOW_JUDGE_DUMP"],
              !path.isEmpty
        else { return }
        let body = "SYSTEM " + escaped(system) + "\nUSER " + escaped(user) + "\n"
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
    /// Newlines only, and backslashes left alone. A harness reverses this with
    /// one `replace("\\n", "\n")`, and escaping the backslash too would need
    /// it to learn a second rule for a character no prompt here contains.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}
