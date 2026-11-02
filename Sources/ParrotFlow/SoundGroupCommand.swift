import Foundation

/// The halves of a sound group that need no model: which terms are in one,
/// what a correction writes, and what a pill answer records.
///
///     ParrotFlow --sound-group Mick
///     members  Mick Mik
///     opens    meek mick mik
///     rule     none
///
///     ParrotFlow --correction Mik Mick --in "Mick is adjusting the piano."
///     use Mick "Mick" heard Mik
///
/// `scripts/check-sound-group.sh` scores them, so the set runs against the
/// shipped functions rather than a copy of them.
enum SoundGroupCommand {

    /// `--sound-group <word>` — the terms that share this word's sound.
    static func group(_ word: String) -> Int32 {
        let config = (try? ConfigStore.load()) ?? Config()
        let groups = SoundGroup.groups(terms: config.vocabulary.terms, uses: TermUses.load())
        let needle = word.lowercased()
        if let held = groups.first(where: { $0.openings.contains(needle) }) {
            print("members  \(held.members.joined(separator: " "))")
            print("opens    \(held.openings.sorted().joined(separator: " "))")
        } else {
            print("no term: \(word)")
        }
        // Whether this word is still a substitution rule. A word that opens a
        // group of two or more is not one, and nothing else shows that half of
        // the change.
        let rule = config.vocabularyRules.first {
            $0.source.caseInsensitiveCompare(word) == .orderedSame
        }
        print("rule     \(rule?.replacement ?? "none")")
        return 0
    }

    /// `--correction <wrote> <put> --in "<sentence>"` — the rows a correction
    /// that runs against a term writes, and the file after it.
    ///
    /// `--dry` prints them without writing. Otherwise they land in
    /// `vocabulary-uses.yaml`, the same call the app makes.
    static func correction(
        wrote: String, put: String, sentence: String?, dry: Bool,
        say: (String) -> Void = { print($0) }
    ) -> Int32 {
        let config = (try? ConfigStore.load()) ?? Config()
        let rows = CorrectionRecording.rows(
            wrote: wrote, put: put, terms: Array(config.vocabulary.terms.keys),
            kinds: config.vocabulary.terms
        )
        // A name with no term yet: the correction panel offers the rendering
        // as a rule, and that writes the term and the use. Written here too,
        // so the command does what the app does.
        if let new = CorrectionRecording.learns(
            wrote: wrote, put: put, in: config.vocabulary.terms
        ) {
            guard !dry else {
                say("learn \(new.name) \(new.kind.rawValue) heard \(wrote)")
                return 0
            }
            do {
                try ConfigWriter.addVocabularyPronunciation(
                    term: new.name, heard: wrote, kind: new.kind
                )
                if let sentence {
                    // Reloaded, because the term was written a line ago and it
                    // is the one that decides which group this row is in.
                    let after = (try? ConfigStore.load()) ?? config
                    try CorrectionRecording.apply(
                        [.use(term: new.name, span: new.name, heard: wrote)], said: sentence,
                        blocking: SoundGroup.groups(
                            terms: after.vocabulary.terms, uses: TermUses.load()
                        )
                    )
                }
            } catch {
                say("✗ \(error.localizedDescription)")
                return 1
            }
            say("learn \(new.name) \(new.kind.rawValue) heard \(wrote)")
            return 0
        }
        guard !rows.isEmpty else {
            say("nothing: \(wrote) is not a term, or the two are the same term")
            return 0
        }
        let groups = SoundGroup.groups(terms: config.vocabulary.terms, uses: TermUses.load())
        if let sentence, let row = rows.first,
           let two = CorrectionRecording.blocked(
               sentence, term: row.term, span: CorrectionRecording.span(of: row), in: groups
           ) {
            say("blocked \(two.joined(separator: " "))")
            return 0
        }
        if !dry, let sentence {
            do {
                let written = try CorrectionRecording.apply(
                    rows, said: sentence, blocking: groups
                )
                guard !written.isEmpty else {
                    say("nothing: \"\(put)\" does not stand in the sentence as a word")
                    return 0
                }
            } catch {
                say("✗ \(error.localizedDescription)")
                return 1
            }
        }
        for row in rows {
            switch row {
            case .use(let term, let span, let heard):
                say("use \(term) \"\(span)\"" + (heard.map { " heard \($0)" } ?? ""))
            case .counter(let term, let span):
                say("counter \(term) \"\(span)\"")
            }
        }
        return 0
    }

    /// `--picked <word> <term> --in "<sentence>"` — what an answer on the pill
    /// records, and it records it.
    ///
    /// Prints `use <term>` or `counter <term>`, or `blocked` and the two
    /// members when the sentence names two members of one group. Keeping the
    /// heard word adds nothing to the vocabulary.
    static func picked(
        word: String, term: String, sentence: String?, dry: Bool,
        say: (String) -> Void = { print($0) }
    ) -> Int32 {
        let terms = ((try? ConfigStore.load()) ?? Config()).vocabulary.terms
        let used = CorrectionRecording.term(named: word, in: Array(terms.keys))
        let row: CorrectionRecording.Row = used.map { .use(term: $0, span: word, heard: nil) }
            ?? .counter(term: term, span: word)
        let groups = SoundGroup.groups(terms: terms, uses: TermUses.load())
        if let sentence, let two = CorrectionRecording.blocked(
            sentence, term: row.term, span: CorrectionRecording.span(of: row), in: groups
        ) {
            say("blocked \(two.joined(separator: " "))")
            return 0
        }
        if let sentence, !dry {
            do {
                try CorrectionRecording.apply(
                    [row], said: sentence, from: .chosen, blocking: groups
                )
            } catch {
                say("✗ \(error.localizedDescription)")
                return 1
            }
        }
        say(used.map { "use \($0)" } ?? "counter \(term)")
        return 0
    }
}
