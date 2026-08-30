import Foundation

/// Would this word be overwritten by a vocabulary term without anything asking?
///
///     ParrotFlow --word-gate Frederick
///     spell      unknown
///     wordpiece  known
///     gate       judge
///
/// The two word lists behind `Vocabulary.autoApplies`, and the decision they
/// reach together. Both verdicts are printed and not just the decision: a word
/// can reach `judge` from either side, and a set that only read the last line
/// would pass while testing the wrong half. This is the entry point
/// `scripts/check-word-gate.sh` scores, so the set runs against the shipped
/// lists rather than a copy of them.
///
/// Name the term and the whole gate answers instead, about that pair:
///
///     ParrotFlow --word-gate "Mirza's" Mirza
///     possessive dropped
///     gate       judge
///
/// One condition of the gate is not about a word at all. A possessive the
/// heard text carries and the term does not is a question about the sentence,
/// so it needs both halves of the proposal — see `Vocabulary.dropsPossessive`.
///
/// Name the sentence too and the model tiers answer as well:
///
///     ParrotFlow --word-gate merge Vercel --in "Go back to main and merge."
///     possessive kept
///     gate       judge
///     slot       Verb
///     rank       not asked
///     route      decline
///
/// `slot` is what the masked slot wants, `rank` is where the span's two-word
/// window sits among the sentence's, and `route` is where the proposal goes —
/// see `SlotGate`. Nothing is downloaded: with no cached model the slot reads
/// `unavailable` and the route is `judge`.
///
/// No audio. The pair form fixes the scores so the term wins, because the
/// acoustic half is not what it is asking; a proposal whose term loses on
/// sound never reaches these conditions.
enum WordGateCommand {
    static func run(word: String, term: String? = nil, sentence: String? = nil) -> Int32 {
        if let term, !term.isEmpty {
            let applies = pair(heard: word, term: term)
            guard let sentence, !sentence.isEmpty else { return 0 }
            guard #available(macOS 14, *) else {
                print("slot       unavailable")
                print("route      judge")
                return 0
            }
            printSlot(heard: word, term: term, in: sentence, applies: applies)
            return 0
        }

        // The slot tiers are about a proposal, so `--in` without a term is a
        // question this cannot answer. Refused rather than ignored: a set that
        // dropped the term would otherwise report the word lists and look like
        // it had scored the route.
        let letters = String(word.filter { $0.isLetter })
        guard !letters.isEmpty, sentence == nil else {
            print("usage: ParrotFlow --word-gate <word> [term] [--in \"<sentence>\"]")
            return 2
        }
        // The decision comes from the shipped test. The two verdicts above it
        // are read from the same lists for the report, so a set can say which
        // half moved — they do not compute the answer.
        let forms = letters == letters.uppercased()
            ? [letters.lowercased()] : [letters, letters.lowercased()]
        print("spell      \(forms.contains { Replacements.isRealWord($0) } ? "known" : "unknown")")
        switch WordPieces.knows(letters) {
        case .some(true):  print("wordpiece  known")
        case .some(false): print("wordpiece  unknown")
        case .none:        print("wordpiece  unavailable")
        }
        print("gate       \(Vocabulary.unseenWord(letters) ? "auto-apply" : "judge")")
        return 0
    }

    /// The gate on one proposal, from the shipped `Vocabulary.autoApplies`.
    ///
    /// The two lists are not printed here. They are not consulted at all on a
    /// span the gate matches glued — `"Matthew at"` — so printing them would
    /// report a lookup that decided nothing.
    private static func pair(heard: String, term: String) -> Bool {
        let drops = Vocabulary.dropsPossessive(heard: heard, term: term)
        print("possessive \(drops ? "dropped" : "kept")")
        let applies = Vocabulary.autoApplies(
            heard: heard, term: term, heardScore: -1, termScore: 0
        )
        print("gate       \(applies ? "auto-apply" : "judge")")
        return applies
    }

    /// The model tiers, on the proposal the lexical gate did not settle.
    ///
    /// Nothing is downloaded. With no cached model the slot is `unavailable`
    /// and the route is `judge`, which is what the app does — see
    /// `Vocabulary.slotRoute`.
    @available(macOS 14, *)
    private static func printSlot(
        heard: String, term: String, in sentence: String, applies: Bool
    ) {
        let config = (try? ConfigStore.load()) ?? Config()
        let language = Pipeline.language(of: sentence, config: config)
        print("language   \(language)")
        guard language == "en" else {
            print("slot       not english")
            print("route      judge")
            return
        }
        guard let range = Vocabulary.spans(of: heard, in: sentence).first else {
            print("slot       not found in the sentence")
            print("route      judge")
            return
        }
        guard let gate = load() else {
            print("slot       unavailable")
            print("route      judge")
            return
        }
        guard let reading = try? gate.read(in: sentence, at: range) else {
            print("slot       unreadable")
            print("route      judge")
            return
        }
        print("slot       \(reading.tag.isEmpty ? "untagged" : reading.tag)")
        // The ten words the tag was taken from. "Determiner" means nothing
        // until you see `second, my, your, any, some` under it.
        let (allWords, span) = SlotGate.sentence(around: range, in: sentence)
        if let guesses = try? gate.tagged(allWords, at: span), !guesses.1.isEmpty {
            print("  fills    " + guesses.1.map { "\($0.word) (\($0.tag))" }
                .joined(separator: ", "))
        }
        if let weighed = try? gate.weighs(allWords, at: span, against: term ?? "") ?? nil {
            print(String(format: "  slot says  here %.2f   there %.2f   %@",
                         weighed.heard, weighed.term,
                         weighed.heard > weighed.term
                            ? "it prefers what is there" : "it prefers the term"))
        }
        print("rank       \(reading.rank.map { "\($0) of \(reading.windows)" } ?? "not asked")")
        // Every word with the number the rank sorted on, least expected first.
        // The rank is a place in that queue and says nothing about the gap to
        // the word behind it, which is the whole of what it gets wrong on a
        // rare proper noun.
        if reading.rank != nil {
            if let ranked = try? gate.ranked(allWords, at: span) {
                for (index, entry) in ranked.1.enumerated() {
                    let mine = span.contains(allWords.firstIndex(of: entry.word) ?? -1)
                    print(String(format: "  %@ %2d  %-18s %7.2f",
                                 mine ? "→" : " ", index, (entry.word as NSString).utf8String!,
                                 entry.score))
                }
            }
        }
        let route = applies
            ? SlotGate.Route.apply
            : (Vocabulary.dropsPossessive(heard: heard, term: term) ? .judge : reading.route)
        print("route      \(route.rawValue)")
    }

    /// The probe, or nil when the model has never been fetched.
    @available(macOS 14, *)
    static func load() -> SlotGate? {
        guard SentenceModel.isCached else { return nil }
        var gate: SlotGate?
        let done = DispatchSemaphore(value: 0)
        Task {
            gate = (try? await SentenceProbe.load()).map(SlotGate.init(probe:))
            done.signal()
        }
        done.wait()
        return gate
    }
}
