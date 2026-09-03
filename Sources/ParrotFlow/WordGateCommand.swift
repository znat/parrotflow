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
///     route      decline
///
/// `slot` is what the masked slot wants and `route` is where the proposal goes
/// — see `SlotGate`. Nothing is downloaded: with no cached model the slot reads
/// `unavailable` and the route is `judge`.
///
/// A span that glues to the term is the one case where the two lines disagree:
///
///     ParrotFlow --word-gate "better stack" BetterStack --in \
///       "I think Node.js and MongoDB is a much better stack than PHP and MySQL."
///     gate       auto-apply (a rule's write is left to the sentence)
///     slot       Adverb
///     route      judge
///
/// The lists are never asked about a glued span, so the gate really does say
/// auto-apply. What happens next depends on where the proposal came from, and
/// that is not something a word and a term can say: a `replacements` rule is
/// left open by `VocabularyJudge.settle`, and the sound path still writes it.
/// The route printed is the rule's, since these two arguments carry no audio.
///
/// The slot is still printed and it still decides nothing. `settle` gates a
/// rule with `.lists`, so the slot is never asked about one — `Adverb` above
/// is in `blocks` and would refuse it, and does not.
///
/// No audio. The pair form fixes the scores so the term wins, because the
/// acoustic half is not what it is asking; a proposal whose term loses on
/// sound never reaches these conditions.
enum WordGateCommand {
    static func run(word: String, term: String? = nil, sentence: String? = nil) -> Int32 {
        if let term, !term.isEmpty {
            let writes = pair(heard: word, term: term)
            guard let sentence, !sentence.isEmpty else { return 0 }
            guard #available(macOS 14, *) else {
                print("slot       unavailable")
                print("route      judge")
                return 0
            }
            printSlot(
                heard: word, term: term, in: sentence,
                applies: writes, glues: Vocabulary.glues(heard: word, term: term)
            )
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
        let glues = applies && Vocabulary.glues(heard: heard, term: term)
        let verdict = applies
            ? (glues ? "auto-apply (a rule's write is left to the sentence)" : "auto-apply")
            : "judge"
        print("gate       \(verdict)")
        // What a rule would do. These arguments carry no audio, so a rule is
        // the proposal this can answer about.
        return applies && !glues
    }

    /// The model tiers, on the proposal the lexical gate did not settle.
    ///
    /// Nothing is downloaded. With no cached model the slot is `unavailable`
    /// and the route is `judge`, which is what the app does — see
    /// `Vocabulary.slotRoute`.
    @available(macOS 14, *)
    private static func printSlot(
        heard: String, term: String, in sentence: String, applies: Bool, glues: Bool
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
        // `apply` is not a route any more — the lexical gate is the only thing
        // that writes without asking, and it has already printed its verdict.
        //
        // A glued span is neither. `settle` gates a rule with `.lists` and
        // never reaches the slot, so the place is left open whatever the tag
        // above says.
        let route: String
        if glues {
            route = "judge"
        } else if applies {
            route = "apply"
        } else if Vocabulary.dropsPossessive(heard: heard, term: term) {
            route = "judge"
        } else {
            route = reading.route.rawValue
        }
        print("route      \(route)")
    }

    /// The probe, or nil when the model has never been fetched.
    @available(macOS 14, *)
    static func load() -> SlotGate? {
        guard SlotModel.isCached else { return nil }
        var gate: SlotGate?
        let done = DispatchSemaphore(value: 0)
        Task {
            gate = (try? await SlotProbe.load()).map(SlotGate.init(probe:))
            done.signal()
        }
        done.wait()
        return gate
    }
}
