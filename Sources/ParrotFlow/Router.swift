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
        /// An edit to the text, but no capability makes it — run `FreeForm`.
        /// Only ever returned when `free_form` is on.
        case anything
        /// Not a request to change the text at all.
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
        freeForm: Bool = false,
        config: LocalLLM.Config
    ) async throws -> Decision {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let raw = try await LocalLLM.complete(
            system: prompt(for: catalogue, freeForm: freeForm),
            user: "instruction: \(trimmed)",
            json: false,
            maxTokens: 8,
            config: config
        )

        return decision(from: raw, catalogue: catalogue, freeForm: freeForm)
    }

    /// Parses a reply into a decision.
    ///
    /// Separate from the call so the validation set can score parsing and
    /// prompting together without a server, and so a model that answers
    /// "bullets." or "> bullets" is not counted as a routing failure when it
    /// is a formatting one.
    static func decision(
        from reply: String, catalogue: Catalogue, freeForm: Bool = false
    ) -> Decision {
        let first = reply
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let cleaned = first
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()

        guard !cleaned.isEmpty, cleaned != "none" else { return .none }
        // Only when it was offered. A model that says ANY unprompted has
        // invented a name, and the line below is already the right home for
        // that — falling through to NONE rather than running something.
        if freeForm, cleaned == "any" { return .anything }
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
    /// With `free_form` on it grows a third answer. Scored by
    /// scripts/validate-gate.py: 18/19 on gemma4:e4b — nine free-form edits to
    /// ANY, five of six idle sentences to NONE, every narrow tool still winning
    /// its own instruction.
    ///
    /// The split is the whole point of the extra answer. NONE used to mean two
    /// things, "not an edit" and "an edit I have no tool for", and a transform
    /// hung off it would inherit every idle sentence — "what is the weather
    /// tomorrow", said with text selected, arriving at a prompt whose one job
    /// is to rewrite the selection. Separating them is what makes `FreeForm`
    /// safe to run without asking first.
    ///
    /// The one failure is the familiar one, a tool name used as an ordinary
    /// noun ("the terse version was better" → terse). Worth noting the other
    /// direction: "I bought a box of bullets", which the notes above record as
    /// this model's floor, passes with the third answer present. The extra
    /// answer costs the existing routing nothing.
    ///
    /// granite4:3b scores 6/19 on the same gate and collapses everything into
    /// one tool. Three-way routing is a gemma-class job, so a smaller model is
    /// a choice about the transform, not about this.
    ///
    /// On the full set, tests/routing-cases.yaml, 41/45 with nothing routed
    /// that should not have been. What it cost to get there, in order:
    ///
    ///     one ANY example, grammar's old description     39/45
    ///     two ANY examples, same description             40/45
    ///     two ANY examples, "not formatting or numbers"   41/45  <- shipped
    ///
    /// The middle step is the interesting one. Removing `dates` and `digits`
    /// left `grammar` as the only entry that mends anything, and it began
    /// taking every "fix the ..." with it. Five rewordings of its description
    /// were measured against a thirteen-case subset and all landed within one
    /// case of each other, 8–10/13, with "fix the numbers" surviving every
    /// one of them — including a description that named numbers as the thing
    /// it does not do. A second ANY example shaped like the failing request
    /// was worth more than any of the rewordings, which is the same lesson as
    /// v2/v3 above arriving from the other direction.
    ///
    /// The description that shipped was kept for a different reason than the
    /// one it was written for: it did not move the ANY cases, but it took
    /// "her grammar is better than mine" back to NONE in both runs it was
    /// measured in. A negative case is worth more here than a positive one.
    static func prompt(for catalogue: Catalogue, freeForm: Bool = false) -> String {
        let example = exampleTransform(in: catalogue)

        let answers = freeForm
            ? "Reply with exactly one tool name from the list above, or ANY, or NONE."
            : "Reply with exactly one tool name from the list above, or NONE."

        // Two rules rather than one when the third answer exists: "no tool does
        // this" and "this is not an edit" stop being the same sentence.
        let closing = freeForm
            ? """
            - Reply ANY when the instruction does ask for a change to the text, \
            but no tool in the list makes that change.
            - Reply NONE when the instruction is not asking for a change to the \
            text at all.
            """
            : "- Reply NONE when no tool does what is being asked."

        // Last, and only when it is an available answer. An ANY example in a
        // prompt that does not offer ANY teaches the model to answer off-list,
        // which is the one failure the parser turns into silence.
        //
        // Two of them, and the second is doing the work. Removing the `dates`
        // and `digits` prompts left `grammar` as the only entry that mends
        // anything, and it started taking every "fix the ..." with it —
        // "format those dates ISO" and "fix the numbers" both routed to
        // grammar. Five rewordings of grammar's description bounced off that
        // (best 10/13, and one of them made it worse), which is the usual sign
        // that the boundary wants an example rather than a rule. So one is
        // shaped like the request that was going wrong, without being one of
        // the cases that scores it.
        let anyExample = freeForm
            ? """


            instruction: put every heading in capitals
            ANY

            instruction: fix the indentation
            ANY
            """
            : ""

        return """
        Choose which tool handles the instruction.

        Tools:
        \(catalogue.listing)

        \(answers) \
        Nothing else — no punctuation, no explanation.

        - Every tool changes text the speaker has already written. Route only \
        when the instruction asks for that. A question, or a remark about \
        something else, is NONE however many words it shares with a tool.
        - The instruction often carries extra detail ("but not the years", \
        "as ISO"). That detail is for the tool, not for you. Route on the request.
        \(closing)

        instruction: \(example.instruction)
        \(example.name)

        \(example.decoys.map { "instruction: \($0)\nNONE" }.joined(separator: "\n\n"))

        instruction: Tasmin spells T A S M E E N
        spelling

        instruction: what is the weather tomorrow
        NONE\(anyExample)
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
    ) -> (name: String, instruction: String, decoys: [String]) {
        let transforms = catalogue.capabilities.filter { $0.isTransform }
        guard let transform = transforms.first else {
            // Built-ins only. The spelling example below carries the positive
            // case on its own, and a decoy for it would teach nothing.
            return (
                name: "vocabulary",
                instruction: "let me fix that word myself",
                decoys: [
                    "how many words did I write yesterday",
                    "we talked about the wording in the meeting",
                ]
            )
        }

        // v4, measured and reverted: a third decoy built from a *second* tool
        // name ("the grammar came up again in standup"), on the theory that one
        // name teaches "bullets can be a noun" rather than the rule. It scored
        // 37/39 — no change — and the two failures were the same two. Both
        // remaining failures are a tool name used as an ordinary noun, and
        // three separate attempts have now bounced off them: a tightened rule
        // (v3, dropped), a second decoy name (v4, dropped), and the original
        // prose rule that was already there. This is the model's floor on this
        // task, not a wording problem, and `confirm` is what makes it
        // survivable — you see the rewrite before it lands.
        return (
            name: transform.name,
            instruction: transform.describedAs,
            decoys: [
                "did you see the \(transform.name) I sent yesterday",
                "we talked about \(transform.name) in the meeting",
            ]
        )
    }
}
