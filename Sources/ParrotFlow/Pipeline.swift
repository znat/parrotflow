import Foundation

/// What happens to a transcript between the model finishing and the text
/// landing in your editor.
///
/// It was always a pipeline — exact replacements, then fuzzy ones, then spoken
/// numbers — but the order lived in one function and each step was switched by
/// a boolean of its own. That works until you want a fourth step, or the same
/// three in a different order for a different language, and neither is
/// expressible in a flag.
///
/// So the order becomes data: a list of stages per language, read from the
/// config. This type is the list and the running of it, and nothing else. Every
/// stage is `String -> String` and already had its own validation set before it
/// was a stage; what is new here is only that they are named, ordered and
/// selected from outside the code.
///
/// The language a transcript is in is resolved here, because it is what picks
/// the pipeline. It is *not* handed down to the stages: `numbers` keeps its own
/// resolution, and has to. Its rule is not "read this language" but "try the
/// detected one, then the others, and let a candidate win only on real
/// evidence" — the guard that stops French reading the "cents" in "I have 99
/// cents" as hundreds. Collapsing that to one language here would quietly
/// delete it.
struct Pipeline: Equatable, Codable {

    /// One step. Deliberately not a closure: a stage has to be nameable in a
    /// config file, comparable in a test, and printable in a log, and a
    /// function value is none of those.
    /// The raw value is the name written in the config, so the two cannot
    /// drift apart — a stage that cannot be spelled is a stage nobody can ask
    /// for.
    enum Stage: String, Equatable, Codable, CaseIterable {
        /// Literal and regex substitutions from `transcription.replacements`.
        case replacements
        /// The same table, used to catch spellings it does not contain.
        /// Meaningless before `replacements` — see `validate`.
        case fuzzy
        /// Spoken numbers as digits, in the language its own pass resolves.
        case numbers
        /// One of the prompts in `prompts:`, run over the whole transcript.
        /// The only stage that calls a model, and the only one that names
        /// something outside itself — see `Step.prompt`.
        case prompt

        var name: String { rawValue }

        /// Whether it can be in a default nobody wrote. `prompt` cannot: it
        /// needs a name, and there is no prompt every install is guaranteed to
        /// have. Everything else is in the default the moment it exists.
        var isAutomatic: Bool { self != .prompt }
    }

    /// A stage plus when it runs. The condition is the whole reason a pipeline
    /// beats a list: a stage that costs a second is affordable exactly when it
    /// can be skipped on the transcripts that do not need it.
    struct Step: Equatable, Codable {
        let stage: Stage
        /// Which prompt, for a `prompt` stage. Meaningless on any other, and
        /// required on that one — a prompt stage with nothing to run is a
        /// config error rather than a stage that does nothing.
        var prompt: String?
        /// Run only when this matches the text as it stands *at this point* —
        /// after the stages before it, not on the original. That ordering is
        /// what lets a cheap deterministic stage make an expensive one
        /// unnecessary rather than merely earlier.
        var when: String?
        /// Skip when this matches. Both may be set; `unless` wins, because a
        /// reason not to run is a stronger statement than a reason to.
        var unless: String?

        /// Same convention as `replacements`, so there is one thing to learn:
        /// between slashes it is a regular expression, otherwise it is a word,
        /// matched on word boundaries. Case-insensitive either way.
        static func pattern(for condition: String) -> String {
            let trimmed = condition.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") else {
                return "\\b\(NSRegularExpression.escapedPattern(for: trimmed))\\b"
            }
            return String(trimmed.dropFirst().dropLast())
        }

        func matches(_ text: String, _ condition: String) -> Bool {
            guard let expression = Step.expression(for: condition) else { return false }
            return expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ) != nil
        }

        /// Compiled once per pattern. A pipeline runs on every transcript, and
        /// rebuilding the same expression each time is work nobody asked for.
        /// Locked, like `Replacements.wordCache` and for the same reason:
        /// `Pipeline.run` is nonisolated and suspends inside a prompt stage for
        /// seconds, so actor reentrancy lets a second transcript's pipeline
        /// reach this while the first is still waiting. A Swift Dictionary
        /// mutated from two threads corrupts or crashes, and the transcript in
        /// flight goes with it.
        private static var cache: [String: NSRegularExpression] = [:]
        private static let cacheLock = NSLock()

        static func expression(for condition: String) -> NSRegularExpression? {
            cacheLock.lock()
            if let cached = cache[condition] { cacheLock.unlock(); return cached }
            cacheLock.unlock()

            guard let built = try? NSRegularExpression(
                pattern: pattern(for: condition), options: [.caseInsensitive]
            ) else { return nil }

            cacheLock.lock()
            cache[condition] = built
            cacheLock.unlock()
            return built
        }

    }

    let steps: [Step]

    var stages: [Stage] { steps.map(\.stage) }

    /// Every stage, in declaration order, which is the canonical order —
    /// numbers last, always, because both name passes match on words and a
    /// mishearing that happens to contain a number word has to still look like
    /// words while they run.
    ///
    /// This is the only default there is. A config that names no pipeline gets
    /// all of it, and a new install is written with the same list spelled out.
    /// Putting a stage in a pipeline is the only way to turn it on, so the way
    /// to turn one off is to delete a line you can already see — rather than to
    /// discover a setting you cannot.
    ///
    /// Derived from `allCases` on purpose: a stage added later is in the
    /// default the moment it exists, which is what keeps that promise true
    /// without anyone having to remember this line.
    ///
    /// An empty list is not the same as no list. `default: []` is a choice and
    /// runs nothing; a missing `pipelines:` is silence and runs everything.
    static let everything = Pipeline(
        steps: Stage.allCases.filter(\.isAutomatic).map { Step(stage: $0) }
    )

    /// The pipeline for a transcript in `language`, from the config.
    ///
    /// A language's own list wins, then `default`, then `unconfigured`. Falling
    /// back rather than merging: a pipeline is an order, and an order that is
    /// half yours and half inherited is not one anybody can read off the page.
    static func resolved(config: Config, language: String) -> Pipeline {
        config.transcription.pipelines[language]
            ?? config.transcription.pipelines["default"]
            ?? everything
    }

    /// The pipeline for this text, and the language it was judged to be in.
    ///
    /// Detection happens here because the pipeline is what it selects. It is
    /// skipped entirely when there is nothing to select between, which is the
    /// common case and saves the recogniser a call.
    static func forText(_ text: String, config: Config) -> (Pipeline, String) {
        let languages = config.transcription.languages
        let language = languages.count > 1
            ? DictationLanguage.detect(text, allowed: languages, fallback: languages.first ?? "en")
            : (languages.first ?? "en")
        return (resolved(config: config, language: language), language)
    }

    /// The stage a config line names, or nil if it names nothing.
    static func stage(named name: String) -> Stage? {
        Stage(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static var stageNames: [String] { Stage.allCases.map(\.rawValue) }

    /// Complaints about a pipeline that would run but not do what it looks
    /// like it does. Returned rather than thrown: one bad line should be
    /// reported, not cost you the other stages.
    ///
    /// `fuzzy` before `replacements` is the one that matters. It reads the same
    /// table and depends on the exact pass having already run — by then
    /// "Superbase" is "Supabase", and without that "on Supabase" scores high
    /// enough against "Supabase" to swallow the preceding word.
    func validate() -> [String] {
        var problems: [String] = []
        for step in steps where step.stage == .prompt && (step.prompt ?? "").isEmpty {
            problems.append("a prompt stage names no prompt — write `- prompt: <name>`")
        }
        for step in steps {
            for (label, condition) in [("when", step.when), ("unless", step.unless)] {
                guard let condition else { continue }
                if Step.expression(for: condition) == nil {
                    // Otherwise the stage simply never runs, which looks
                    // exactly like the stage being broken.
                    problems.append("\(step.stage.name): \(label) \"\(condition)\" is not a valid pattern")
                }
            }
        }
        if let fuzzy = stages.firstIndex(of: .fuzzy) {
            guard let exact = stages.firstIndex(of: .replacements) else {
                problems.append("fuzzy has no replacements before it; it reads that table and will find nothing")
                return problems
            }
            if fuzzy < exact {
                problems.append("fuzzy runs before replacements; it needs the exact pass to have run first")
            }
        }
        return problems
    }

    /// Asynchronous because one stage calls a model.
    ///
    /// The alternative was a semaphore inside the prompt stage, and this runs
    /// on a cooperative thread after transcription — blocking one there for up
    /// to the LLM timeout is how a thread pool stops being a thread pool. The
    /// deterministic stages suspend nowhere, so the cost of this is a keyword.
    /// Why a step would not run, or nil if it would.
    ///
    /// One copy, because there were two: `run` decided, and the stage-by-stage
    /// viewer in `--pipeline` decided again from `shouldRun` alone — which knew
    /// nothing about the wake-phrase guard, so a prompt the pipeline had
    /// skipped was reported as having "ran, changed nothing". A diagnostic that
    /// disagrees with the thing it is diagnosing is worse than none.
    static func skipReason(
        for step: Step, text: String, config: Config, allowPrompts: Bool
    ) -> String? {
        if step.stage == .prompt {
            if !allowPrompts { return "prompts are off on this path" }
            if VoiceCommand.commandAfterWakePhrase(
                text, phrase: config.transcription.activationPhrase
            ) != nil {
                return "this is a spoken command"
            }
        }
        if let unless = step.unless, step.matches(text, unless) {
            return "unless \(unless) matched"
        }
        if let when = step.when, !step.matches(text, when) {
            return "when \(when) did not match"
        }
        return nil
    }

    func run(_ text: String, config: Config, allowPrompts: Bool = true) async -> String {
        var output = text
        for step in steps {
            if let reason = Pipeline.skipReason(
                for: step, text: output, config: config, allowPrompts: allowPrompts
            ) {
                // Said out loud: a stage that silently does not run is
                // indistinguishable from one that ran and found nothing, and
                // only one of those is answerable by editing a condition.
                let named = step.prompt.map { "\(step.stage.name) \($0)" } ?? step.stage.name
                Log.write("pipeline: skipped \(named) — \(reason)")
                continue
            }
            output = await apply(step, to: output, config: config)
        }
        return output
    }

    private func apply(_ step: Step, to text: String, config: Config) async -> String {
        switch step.stage {
        case .replacements:
            return Replacements.applyExact(to: text, rules: config.transcription.rules)
        case .fuzzy:
            let targets = config.transcription.replacements.keys.filter { !$0.isEmpty }
            return Replacements.applyFuzzy(to: text, targets: Array(targets))
        case .numbers:
            return Numbers.apply(to: text, languages: config.transcription.languages)
        case .prompt:
            return await runPrompt(step, on: text, config: config)
        }
    }

    /// The only stage that can fail, and the only one that must not fail loudly.
    ///
    /// Ollama not running is an ordinary state for this app, and a transcript is
    /// the one thing a dictation tool cannot afford to drop: every way this goes
    /// wrong returns the text exactly as it arrived. What it does not do is go
    /// quiet — a model rewriting your words is the one stage whose before and
    /// after belong in the log whether or not anything went wrong, because
    /// nothing on screen will ever show you it happened.
    private func runPrompt(_ step: Step, on text: String, config: Config) async -> String {
        guard let name = step.prompt else {
            Log.write("pipeline: a prompt stage names no prompt; skipped")
            return text
        }
        guard config.llm.enabled else {
            Log.write("pipeline: skipped prompt \(name) — llm.enabled is false")
            return text
        }
        guard let prompt = config.prompts.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            Log.write("pipeline: no prompt named \"\(name)\"; skipped")
            return text
        }

        do {
            let result = try await PromptRunner.run(
                prompt: prompt,
                instruction: "",
                text: text,
                config: LocalLLM.Config(
                    endpoint: config.llm.endpoint,
                    model: config.llm.model,
                    timeout: config.llm.timeoutSeconds,
                    keepLoaded: config.llm.keepLoaded
                )
            )
            guard !result.isEmpty else {
                Log.write("pipeline: prompt \(name) returned nothing; kept the transcript")
                return text
            }
            if result != text {
                Log.write("pipeline: prompt \(name) rewrote the transcript")
                Log.write("    before: \(text)")
                Log.write("    after:  \(result)")
            }
            return result
        } catch {
            Log.write("pipeline: prompt \(name) failed (\(error.localizedDescription));"
                + " kept the transcript")
            return text
        }
    }
}
