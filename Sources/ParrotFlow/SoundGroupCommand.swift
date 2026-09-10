import Foundation

/// The three halves of a sound group that need no model: which terms are in
/// one, what the decision rule does with scores, and what a correction writes.
///
///     ParrotFlow --sound-group Mick
///     members  Mick Mik
///     opens    meek mick mik
///     rule     none
///
///     ParrotFlow --group-decide Mik:0.90:0.80 Mick:0.86:- --plain 0.70
///     Mik    0.900  floor 0.800  stands
///     Mick   0.860  floor —      stands
///     plain  0.700
///     write Mik
///
///     ParrotFlow --correction Mik Mick --in "Mick is adjusting the piano."
///     use Mick "Mick" heard Mik
///
/// `scripts/check-sound-group.sh` scores all three, so the set runs against
/// the shipped functions rather than a copy of them. The whole thing with a
/// model behind it is `--portrait <heard> "<sentence>"`.
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

    /// `--name-place <heard> <term>` — whether the slot test stands aside here.
    ///
    /// `names` means both sides are names and the slot cannot separate them;
    /// `ordinary` means an ordinary word against a term, which is the place the
    /// slot exists for. See `NamePlace`.
    static func namePlace(heard: String, term: String) -> Int32 {
        let config = (try? ConfigStore.load()) ?? Config()
        let names = NamePlace.bothNames(heard: heard, term: term, in: config.vocabulary.terms)
        print(names ? "names" : "ordinary")
        return 0
    }

    /// `--group-decide <term>:<score>:<floor>[:<uses>] … [--plain <score>]`
    ///
    /// A floor of `-` is a member with too few uses to have one, which never
    /// falls out on that ground. A score of `-` is a member that could not be
    /// scored, and `:0` at the end is a member nobody has ever confirmed —
    /// unknown, which is not the same as out.
    static func decide(_ members: [String], plain: Double?) -> Int32 {
        var candidates: [SoundGroup.Candidate] = []
        for member in members {
            let parts = member.split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 3 || parts.count == 4 else {
                print("a member is <term>:<score>:<floor>[:<uses>], not \"\(member)\"")
                return 2
            }
            candidates.append(SoundGroup.Candidate(
                name: parts[0], score: Double(parts[1]), floor: Double(parts[2]),
                uses: parts.count == 4 ? (Int(parts[3]) ?? 1) : 1
            ))
        }
        for candidate in candidates {
            let floor = candidate.floor.map { String(format: "%.3f", $0) } ?? "—"
            let score = candidate.score.map { String(format: "%.3f", $0) } ?? "—"
            let how = candidate.unknown ? "unknown" : (candidate.stands ? "stands" : "out")
            print("\(pad(candidate.name, 10))  \(pad(score, 5))  floor \(pad(floor, 5))  \(how)")
        }
        if let plain { print(String(format: "%@  %.3f", pad("plain", 10), plain)) }
        print(said(SoundGroup.decide(candidates, plain: plain)))
        return 0
    }

    /// What a verdict is called, which is the line a check script reads.
    static func said(_ verdict: SoundGroup.Verdict) -> String {
        switch verdict {
        case .write(let term): return "write \(term)"
        case .keep: return "keep"
        case .open(let members): return "open \(members.joined(separator: " "))"
        }
    }

    /// `--correction <wrote> <put> --in "<sentence>"` — the rows a correction
    /// that runs against a term writes, and the file after it.
    ///
    /// `--dry` prints them without writing. Otherwise they land in
    /// `vocabulary-uses.yaml`, the same call the app makes.
    static func correction(
        wrote: String, put: String, sentence: String?, dry: Bool
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
                print("learn \(new.name) \(new.kind.rawValue) heard \(wrote)")
                return 0
            }
            do {
                try ConfigWriter.addVocabularyPronunciation(
                    term: new.name, heard: wrote, kind: new.kind
                )
                if let sentence {
                    try CorrectionRecording.apply(
                        [.use(term: new.name, span: new.name, heard: wrote)], said: sentence
                    )
                }
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
            print("learn \(new.name) \(new.kind.rawValue) heard \(wrote)")
            return 0
        }
        guard !rows.isEmpty else {
            print("nothing: \(wrote) is not a term, or the two are the same term")
            return 0
        }
        let groups = SoundGroup.groups(terms: config.vocabulary.terms, uses: TermUses.load())
        if let sentence, let row = rows.first,
           let two = CorrectionRecording.blocked(sentence, term: row.term, in: groups) {
            print("blocked \(two.joined(separator: " "))")
            return 0
        }
        if !dry, let sentence {
            do {
                let written = try CorrectionRecording.apply(
                    rows, said: sentence, blocking: groups
                )
                guard !written.isEmpty else {
                    print("nothing: \"\(put)\" does not stand in the sentence as a word")
                    return 0
                }
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
        }
        for row in rows {
            switch row {
            case .use(let term, let span, let heard):
                print("use \(term) \"\(span)\"" + (heard.map { " heard \($0)" } ?? ""))
            case .counter(let term, let span):
                print("counter \(term) \"\(span)\"")
            }
        }
        return 0
    }

    /// `--picked <word> <term> --in "<sentence>"` — what an answer on the pill
    /// records, and it records it.
    ///
    /// Prints `use <term>`, `create <name> <kind>` — a name written to
    /// `vocabulary.yaml` and then used — or `counter <term>`, and `blocked` in
    /// front of any of them when the sentence names two members of one group.
    static func picked(word: String, term: String, sentence: String?, dry: Bool) -> Int32 {
        let config = (try? ConfigStore.load()) ?? Config()
        var answer = CorrectionRecording.picked(
            word, proposedBy: term, in: config.vocabulary.terms
        )
        if case .create(let name, let kind) = answer, !dry {
            do {
                try ConfigWriter.addVocabularyTerm(name, kind: kind)
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
        }
        let row: CorrectionRecording.Row
        switch answer {
        case .use(let already): row = .use(term: already, span: word, heard: nil)
        case .create(let name, _): row = .use(term: name, span: word, heard: nil)
        case .counter(let proposed): row = .counter(term: proposed, span: word)
        }
        let groups = SoundGroup.groups(
            terms: (try? ConfigStore.load())?.vocabulary.terms ?? [:], uses: TermUses.load()
        )
        if let sentence, let two = CorrectionRecording.blocked(
            sentence, term: row.term, in: groups
        ) {
            print("blocked \(two.joined(separator: " "))")
            return 0
        }
        if let sentence, !dry {
            do {
                try CorrectionRecording.apply([row], said: sentence, from: .chosen)
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
        }
        switch answer {
        case .use(let already): print("use \(already)")
        case .create(let name, let kind): print("create \(name) \(kind.rawValue)")
        case .counter(let proposed): print("counter \(proposed)")
        }
        return 0
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
