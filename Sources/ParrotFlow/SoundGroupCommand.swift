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

    /// `--group-decide <term>:<score>:<floor> … [--plain <score>]`
    ///
    /// A floor of `-` is a member with too few uses to have one, which never
    /// falls out on that ground.
    static func decide(_ members: [String], plain: Double?) -> Int32 {
        var candidates: [SoundGroup.Candidate] = []
        for member in members {
            let parts = member.split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 3, let score = Double(parts[1]) else {
                print("a member is <term>:<score>:<floor>, not \"\(member)\"")
                return 2
            }
            candidates.append(SoundGroup.Candidate(
                name: parts[0], score: score, floor: Double(parts[2])
            ))
        }
        for candidate in candidates {
            let floor = candidate.floor.map { String(format: "%.3f", $0) } ?? "—"
            print(String(
                format: "%@  %.3f  floor %@  %@", pad(candidate.name, 10), candidate.score,
                pad(floor, 5), candidate.stands ? "stands" : "out"
            ))
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
            wrote: wrote, put: put, terms: Array(config.vocabulary.terms.keys)
        )
        guard !rows.isEmpty else {
            print("nothing: \(wrote) is not a term, or the two are the same term")
            return 0
        }
        if !dry, let sentence {
            do {
                let written = try CorrectionRecording.apply(rows, said: sentence)
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

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
