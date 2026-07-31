import Foundation

/// Decides which capability a spoken instruction is asking for.
///
/// It classifies and nothing more. It does not pull arguments out of the
/// sentence — the whole instruction is passed on to whatever it picked,
/// routing words included, because the rest of the sentence is usually the
/// interesting half: "fix the numbers **but leave the years alone**", "format
/// those dates **ISO**". Splitting that out would be a second extraction step
/// to get subtly wrong on a sentence nobody anticipated, and there is nothing
/// a prompt cannot read for itself.
enum Router {

    enum Decision: Equatable {
        case matched(Capability)
        /// Understood, but nothing in the catalogue fits.
        case none
    }

    /// Similarity above which a spoken name is taken as naming a capability.
    ///
    /// High, because this path skips the model entirely. "bullets" said aloud
    /// should hit it; "make that a list" should not, and should go to the
    /// router where the descriptions can do their job.
    static let nameThreshold = 0.85

    // MARK: - Local

    /// Naming a capability outright, with no model involved.
    ///
    /// Worth having twice over: it removes a round trip from the commands you
    /// use most, and it is the only path that works when Ollama is not running.
    ///
    /// Only the opening words are considered. "bullets" and "bullets but keep
    /// the headings" both name `bullets`; "I was thinking about bullets"
    /// should not, and does not, because the match is anchored at the start.
    static func local(instruction: String, catalogue: Catalogue) -> Capability? {
        let words = instruction.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var best: (capability: Capability, score: Double)?
        for capability in catalogue.capabilities {
            let target = capability.name.lowercased()
            // A capability's name may be more than one word, so try the same
            // number of leading words as the name has, and one either side.
            let nameWords = target.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.count
            for count in 1...max(1, min(nameWords + 1, words.count)) {
                let candidate = words.prefix(count).joined(separator: " ")
                let score = VoiceCommand.similarity(candidate, target)
                if score >= nameThreshold, score > (best?.score ?? 0) {
                    best = (capability, score)
                }
            }
        }
        return best?.capability
    }

    // MARK: - Model

    /// Asks the model which capability the instruction is for.
    ///
    /// The answer is one name from a list the model was just shown, or NONE —
    /// deliberately the same shape as the spelling extractor, for the same
    /// reason. A short constrained answer is cheap, fast on a pinned model, and
    /// parses rather than needing to be understood. `NO MATCH` there taught the
    /// lesson this reuses: give a model somewhere to put "nothing", or it will
    /// invent something rather than emit no tokens.
    static func route(
        instruction: String,
        catalogue: Catalogue,
        config: LocalLLM.Config
    ) async throws -> Decision {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let raw = try await LocalLLM.complete(
            system: prompt(for: catalogue),
            user: "instruction: \(trimmed)",
            json: false,
            maxTokens: 8,
            config: config
        )

        return decision(from: raw, catalogue: catalogue)
    }

    /// Parses a reply into a decision.
    ///
    /// Separate from the call so the validation set can score parsing and
    /// prompting together without a server, and so a model that answers
    /// "bullets." or "> bullets" is not counted as a routing failure when it
    /// is a formatting one.
    static func decision(from reply: String, catalogue: Catalogue) -> Decision {
        let first = reply
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let cleaned = first
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()

        guard !cleaned.isEmpty, cleaned != "none" else { return .none }
        guard let capability = catalogue.capability(named: cleaned) else {
            // A name that is not in the catalogue is a hallucination, not a
            // near miss to be resolved — matching it to the closest entry is
            // how an unrelated instruction ends up rewriting your text.
            Log.write("router: \"\(cleaned)\" is not a known capability")
            return .none
        }
        return .matched(capability)
    }

    /// The routing prompt. Scored by tests/routing-cases.yaml.
    ///
    /// Three things carried over from the extraction prompt, which cost
    /// measurement to learn there and are free here. NONE is spelled out as an
    /// option rather than described as "reply with nothing". The examples do
    /// the work that prose rules did badly. And the negative example is not
    /// optional — without one, every sentence finds a home.
    ///
    /// Scored on gemma4:e4b, in the order the changes were made:
    ///
    ///     v1  two examples, one matching, one unrelated   28/32
    ///     v2  + a decoy question sharing the vocabulary   30/32
    ///     v3  + a decoy statement sharing it              31/32
    ///
    /// Every v1 failure was one shape: a sentence mentioning a tool's subject
    /// while asking for something else. "I bought a box of bullets" went to
    /// `bullets`, "what date is the retro" to `dates`. A prose rule against
    /// exactly that was already in the prompt and did nothing. What worked was
    /// showing the case — the model had seen a match and a non-match that
    /// shared no vocabulary at all, so "shares words but is not a request" was
    /// a category it had no example of.
    ///
    /// The decoys are generated, not copied from the set, so the four cases in
    /// tests/routing-cases.yaml stayed honest measurements of a prompt that had
    /// never seen them.
    ///
    /// One still fails: "I bought a box of bullets". Tightening the rule to
    /// "an order to change the text" left it at 31/32 and was dropped for
    /// buying nothing. It is the residue of a name that is an ordinary noun,
    /// and `confirm` is what makes it survivable — you see the rewrite before
    /// it lands.
    static func prompt(for catalogue: Catalogue) -> String {
        let example = exampleTransform(in: catalogue)

        return """
        Choose which tool handles the instruction.

        Tools:
        \(catalogue.listing)

        Reply with exactly one tool name from the list above, or NONE. \
        Nothing else — no punctuation, no explanation.

        - Every tool changes text the speaker has already written. Route only \
        when the instruction asks for that. A question, or a remark about \
        something else, is NONE however many words it shares with a tool.
        - The instruction often carries extra detail ("but not the years", \
        "as ISO"). That detail is for the tool, not for you. Route on the request.
        - Reply NONE when no tool does what is being asked.

        instruction: \(example.instruction)
        \(example.name)

        instruction: \(example.decoy)
        NONE

        instruction: \(example.statement)
        NONE

        instruction: Tasmin spells T A S M E E N
        spelling

        instruction: what is the weather tomorrow
        NONE
        """
    }

    /// A worked example built from a tool that actually exists.
    ///
    /// Examples are the strongest signal in the prompt, so one naming a tool
    /// the model was not given teaches it to answer off-list — the single
    /// failure this design cannot recover from, since an unknown name becomes
    /// NONE. The decoy is generated from the same name so the pair reads as
    /// "these words, this request" against "these words, not a request".
    private static func exampleTransform(
        in catalogue: Catalogue
    ) -> (name: String, instruction: String, decoy: String, statement: String) {
        guard let transform = catalogue.capabilities.first(where: { $0.isTransform }) else {
            // Built-ins only. The spelling example below carries the positive
            // case on its own, and a decoy for it would teach nothing.
            return (
                name: "vocabulary",
                instruction: "let me fix that word myself",
                decoy: "how many words did I write yesterday",
                statement: "we talked about the wording in the meeting"
            )
        }
        return (
            name: transform.name,
            instruction: transform.describedAs,
            decoy: "did you see the \(transform.name) I sent yesterday",
            statement: "we talked about \(transform.name) in the meeting"
        )
    }
}
