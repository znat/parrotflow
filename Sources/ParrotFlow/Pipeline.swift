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
        /// What is on screen around the field, published as `context.*` and
        /// never written into the transcript. Terminals only — see `Context`.
        case context
        /// The names the acoustic pass was unsure about, put to a model as a
        /// menu of whole sentences — see `VocabularyJudge`. Named by a prompt
        /// file, `- vocabulary: verify_names.md`.
        case vocabulary
        /// One of the entries in `transforms:`, run over the whole
        /// transcript. The only stage that names something outside itself, and
        /// the only one that might call a model — see `Step.transform`.
        case transform

        var name: String { rawValue }

        /// Whether the stage rewrites the transcript.
        ///
        /// Only used to say where `vocabulary` belongs: it reads spans the
        /// acoustic pass measured before the pipeline started, and every stage
        /// that edits text moves them (F10). `replacements` is the exception it
        /// has to live with — the judge offers a rule's substitution back, so
        /// the rules must already have fired.
        var editsText: Bool { self != .context && self != .vocabulary }

        /// Whether it can be in a default nobody wrote.
        ///
        /// `transform` cannot: it needs a name, and there is no transform every
        /// install is guaranteed to have. `vocabulary` cannot either, for the
        /// same reason — it names a prompt file.
        ///
        /// `context` cannot, for a different and stronger reason. It reads the
        /// screen. Turning that on for everybody who never wrote a `pipelines:`
        /// block would be a silent change to what the app looks at, which is the
        /// one kind of change that has to be asked for by name.
        var isAutomatic: Bool {
            self != .transform && self != .context && self != .vocabulary
        }
    }

    /// The app a transcript is on its way into, for `Step.app`.
    ///
    /// Captured when the hotkey goes down, never read at stage time. Between
    /// the two there is a transcription and possibly a model call, and the
    /// window you were dictating into is not reliably the one still in front
    /// when the text comes back. `SelectionReader.snapshot()` takes the owner
    /// at press for the same reason, and this rides along with it.
    ///
    /// Name and bundle identifier are matched as **one string**, not either-or.
    /// The name is what you know an app by and the identifier is what stays
    /// put, so both have to be reachable — but two haystacks and a negative
    /// pattern do not mix: `/^(?!.*microsoft)/` matches "Code" while failing
    /// `com.microsoft.VSCode`, and "one of the two matched" would then run the
    /// stage in the app it was written to exclude. Joined, the question has one
    /// answer.
    struct App: Equatable {
        let name: String
        let bundleID: String

        /// What a pattern is matched against.
        var searchable: String { "\(name) \(bundleID)" }

        /// How it reads in a log line.
        var described: String { name.isEmpty ? bundleID : name }
    }

    /// A stage plus when it runs. The condition is the whole reason a pipeline
    /// beats a list: a stage that costs a second is affordable exactly when it
    /// can be skipped on the transcripts that do not need it.
    struct Step: Equatable, Codable {
        let stage: Stage
        /// Which entry of `transforms:`, for a `transform` stage. Meaningless
        /// on any other, and required on that one — a transform stage with
        /// nothing to run is a config error rather than a stage that quietly
        /// does nothing.
        var transform: String?
        /// The prompt file a `vocabulary` stage asks with, resolved against the
        /// directory the config was read from. Absolute paths and `~` are their
        /// own answer.
        ///
        /// Not `transform:`. That name is the namespace a stage's variables are
        /// filed under, and filing a stage's facts under `verify_names.md`
        /// would put a filename in every condition that reads them.
        var prompt: String?
        /// How large the menu may get — see `VocabularyJudge.Caps`. Absent on
        /// every other stage.
        var caps: VocabularyJudge.Caps?
        /// Run only when this matches the text as it stands *at this point* —
        /// after the stages before it, not on the original. That ordering is
        /// what lets a cheap deterministic stage make an expensive one
        /// unnecessary rather than merely earlier.
        var when: String?
        /// Skip when this matches. Both may be set; `unless` wins, because a
        /// reason not to run is a stronger statement than a reason to.
        var unless: String?
        /// Run only in apps this matches — see `App`.
        ///
        /// There is no `not_app`, deliberately: the pattern is a regular
        /// expression like every other one here, so exclusion is a negative
        /// lookahead, `/^(?!.*term)/`. That keeps one key instead of two, at
        /// the cost of an anchor people forget — which `validate` refuses
        /// rather than leaving to run everywhere in silence.
        var app: String?

        /// Whether a condition is a pattern rather than an expression.
        ///
        /// Between slashes it is a regular expression — the form every condition
        /// in this app has ever been written in. Anything else is now read as an
        /// expression over the pipeline's variables, which is the only way
        /// `code_identifiers.count == 0` could be spelled at all.
        ///
        /// That does take a form away. A bare word used to mean "this word
        /// appears, on word boundaries", and now parses as a variable nobody
        /// defined. It was documented and never used — not in the default
        /// config, not in an example, not in a fixture — and the alternative was
        /// two condition languages in one key forever. `validate` refuses the
        /// old form by name and says what to write instead, so a config that
        /// used it fails at `--check-config` rather than at the moment a stage
        /// quietly stops running.
        static func isPattern(_ condition: String) -> Bool {
            let trimmed = condition.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 2 && trimmed.hasPrefix("/") && trimmed.hasSuffix("/")
        }

        /// The regular expression inside the slashes. A condition that is not a
        /// pattern has none, and asking is a programming error rather than a
        /// config one — `isPattern` decides first, everywhere.
        static func pattern(for condition: String) -> String {
            let trimmed = condition.trimmingCharacters(in: .whitespaces)
            guard isPattern(trimmed) else { return trimmed }
            return String(trimmed.dropFirst().dropLast())
        }

        func matches(_ text: String, _ condition: String) -> Bool {
            guard let expression = Step.expression(for: condition) else { return false }
            return expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ) != nil
        }

        /// Whether a condition holds, whichever of the two forms it is in.
        ///
        /// `subject` is what a *pattern* is matched against — the text for
        /// `when:` and `unless:`, the app for `app:`. An expression ignores it
        /// and reads the scope, where the same things are available by name.
        ///
        /// Throws only for an expression, and only for the mistakes that have no
        /// sensible false: a name nothing defines, a comparison between a string
        /// and a number. Returning false for those is the silent failure this
        /// design exists to remove — a stage that never runs looks exactly like
        /// a stage that is broken, and only one of them is answerable by editing
        /// a line.
        func holds(_ condition: String, subject: String, scope: Scope) throws -> Bool {
            guard !Step.isPattern(condition) else { return matches(subject, condition) }
            return try Condition.evaluate(condition, in: scope)
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
    ///
    /// "prompt" still resolves, because `- prompt: grammar` is what every
    /// pipeline written before `transforms:` says and there is no reading of it
    /// that has become ambiguous — a prompt is a transform with a prompt body.
    static func stage(named name: String) -> Stage? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "prompt" { return .transform }
        return Stage(rawValue: key)
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
        for step in steps where step.stage == .transform && (step.transform ?? "").isEmpty {
            problems.append("a prompt stage names no prompt — write `- prompt: <name>`")
        }
        for step in steps where step.stage == .vocabulary {
            if (step.prompt ?? "").isEmpty {
                problems.append("a vocabulary stage names no prompt file"
                    + " — write `- vocabulary: <file.md>`")
            }
            problems += step.caps?.problems ?? []
        }
        problems += vocabularyOrderProblems()
        // Which namespaces a condition on this step is allowed to read: the
        // seeds, plus every stage *above* it. Built as the list is walked, which
        // is what makes the ordering check possible at all — a condition reading
        // a stage declared below it has no value to read, and at run time that
        // is indistinguishable from the stage having reported nothing.
        var available = Scope.reserved
        for step in steps {
            if step.stage == .transform, let name = step.transform,
               Scope.reserved.contains(name) {
                problems.append(
                    "a transform called \"\(name)\" would file its variables where"
                        + " \(name) already is — rename it"
                )
            }
            for (label, condition) in [
                ("when", step.when), ("unless", step.unless), ("app", step.app)
            ] {
                guard let condition else { continue }
                guard Step.isPattern(condition) else {
                    problems += expressionProblems(
                        condition, label: label, step: step, available: available
                    )
                    continue
                }
                if Step.expression(for: condition) == nil {
                    // Otherwise the stage simply never runs, which looks
                    // exactly like the stage being broken.
                    problems.append("\(step.stage.name): \(label) \"\(condition)\" is not a valid pattern")
                    continue
                }
                // A negative lookahead is how exclusion is written here, and
                // unanchored it is a lie: patterns are matched with
                // `firstMatch`, so `/(?!.*term)/` succeeds one character into
                // "Terminal" and the stage runs everywhere it was meant to be
                // kept out of. Nothing about that failure is visible — the
                // stage does not error, it just runs — so it is refused here.
                //
                // An expression does not need this and does not get it: `!` is
                // a real negation, so exclusion is `!app.matches("term")` and
                // the anchor nobody remembers stops existing.
                if Step.pattern(for: condition).hasPrefix("(?!") {
                    problems.append(
                        "\(step.stage.name): \(label) \"\(condition)\" is an unanchored negative"
                            + " lookahead — it matches almost anything. Anchor it: /^(?!.*…)/"
                    )
                }
            }
            available.insert(Pipeline.namespace(of: step))
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

    /// Stages that move the words `vocabulary` is about to talk about.
    ///
    /// The judge is handed spans the acoustic pass measured on the transcript
    /// as the decoder produced it. A stage that rewrites text moves them, and
    /// the stage then has to re-anchor by searching for the words — which is
    /// the mechanism that put the menu on the wrong `Versailles` (F3, F10).
    ///
    /// `replacements` is not listed. The judge offers a rule's substitution
    /// back as a reading, so the rules have to have fired first; that is the
    /// one edit this stage is built to survive, by searching for the term. Put
    /// `replacements` above `vocabulary:` and everything else below it.
    private func vocabularyOrderProblems() -> [String] {
        guard let judge = stages.firstIndex(of: .vocabulary) else { return [] }
        let above = steps[..<judge]
            .filter { $0.stage.editsText && $0.stage != .replacements }
            .map { Pipeline.namespace(of: $0) }
        guard !above.isEmpty else { return [] }
        return ["vocabulary runs after \(above.joined(separator: ", ")), which rewrite the"
            + " transcript — the spans it was given no longer point at the same words."
            + " Order: replacements, vocabulary, then the rest"]
    }

    /// What is wrong with an expression, before a transcript ever reaches it.
    ///
    /// Two kinds of thing, and the second is the one worth having. A parse error
    /// would surface on the first dictation anyway; **reading a stage that runs
    /// later** would not, because at run time "the stage below has not published
    /// anything yet" and "the stage published nothing" are the same absence.
    /// Only the pipeline as a whole knows the order, so only here can the
    /// difference be seen — which is the same argument that already refuses
    /// `fuzzy` before `replacements`.
    private func expressionProblems(
        _ condition: String, label: String, step: Step, available: Set<String>
    ) -> [String] {
        let named = step.transform.map { "\(step.stage.name) \($0)" } ?? step.stage.name
        do {
            _ = try Condition.parse(condition)
        } catch {
            let message = (error as? Condition.Failure)?.message ?? error.localizedDescription
            return ["\(named): \(label) \"\(condition)\" — \(message)"]
        }

        var problems: [String] = []
        for path in Condition.roots(of: condition).sorted() {
            // A bare name is either a seed or the old word-boundary form. The
            // second is why this branch says what to write instead: `when: genre`
            // meant something for as long as this app has had conditions, and a
            // config carrying one should be told, not silently re-read.
            guard path.contains(".") else {
                if !Scope.reserved.contains(path) {
                    problems.append(
                        "\(named): \(label) \"\(condition)\" reads \"\(path)\", which is not a"
                            + " variable. If you meant the word \"\(path)\" in the text, write it"
                            + " as a pattern: /\(path)/"
                    )
                }
                continue
            }
            let namespace = String(path.prefix(while: { $0 != "." }))
            guard available.contains(namespace) else {
                let later = steps.contains { Pipeline.namespace(of: $0) == namespace }
                problems.append(
                    "\(named): \(label) \"\(condition)\" reads \"\(path)\", but "
                        + (later
                            ? "\"\(namespace)\" runs *after* this stage — a condition can only"
                                + " read a stage above it"
                            : "nothing in this pipeline is called \"\(namespace)\"")
                )
                continue
            }
            // `text.matches(…)` and friends: `text` is a seed and a namespace
            // prefix is not, so a path under a stage is only ever a variable.
            // `asr`, `vad` and `vocabulary` are seeded as groups by the
            // transcriber; the rest of the reserved names are bare strings, so
            // a dotted path under one of those is a mistake.
            if Scope.reserved.contains(namespace),
               !["asr", "vad", "vocabulary"].contains(namespace) {
                problems.append(
                    "\(named): \(label) \"\(condition)\" reads \"\(path)\", but \"\(namespace)\""
                        + " is text rather than a group of variables"
                )
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
    /// Why a stage did not run, in both registers.
    ///
    /// `described` names the actual pattern, which is what you need to fix a
    /// condition. `code` is the category, which is what you need to count —
    /// and the prose cannot be counted, because every branch below phrases it
    /// differently and two of them interpolate a regex.
    struct Skip {
        let code: String
        let described: String
    }

    static func skipReason(
        for step: Step, text: String, config: Config, allowPrompts: Bool, app: App? = nil,
        scope: Scope = Scope()
    ) -> Skip? {
        if step.stage == .vocabulary {
            // It costs a model call, so it answers to the same two guards a
            // prompt does: `--replace` must stay off the network, and a spoken
            // instruction is not a dictation whose names want checking.
            if !allowPrompts {
                return Skip(code: "prompts_off", described: "prompts are off on this path")
            }
            let phrases = config.transcription.activationPhrases
            if VoiceCommand.commandAfterWakePhrase(text, phrases: phrases) != nil {
                return Skip(code: "spoken_command", described: "this is a spoken command")
            }
            if VoiceCommand.inlineInstruction(text, phrases: phrases) != nil {
                return Skip(
                    code: "inline_instruction",
                    described: "this carries an instruction of its own"
                )
            }
        }
        if step.stage == .transform {
            // Only the prompt-bodied ones. `allowPrompts` is there to keep
            // `--replace` off the network, and a `replace:` transform is a
            // table — blocking it would make the flag mean "no transforms",
            // which is not what any caller asked for.
            //
            // A name that resolves to nothing counts as a prompt, which is the
            // conservative reading: the stage is about to be skipped anyway,
            // and the one thing this must not do is let an unresolved name
            // become a way onto the network.
            let named = step.transform.flatMap { config.transform(named: $0) }
            if !allowPrompts, named?.isPrompt ?? true {
                return Skip(code: "prompts_off", described: "prompts are off on this path")
            }
            // Either position. A phrase at the front means the whole utterance
            // is an instruction; one in the middle means the instruction is
            // about the words before it. Both are read after this runs, and a
            // transform that rewrote the sentence first could eat the phrase
            // and leave what should have been a command to be typed into the
            // document.
            let phrases = config.transcription.activationPhrases
            if VoiceCommand.commandAfterWakePhrase(text, phrases: phrases) != nil {
                return Skip(code: "spoken_command", described: "this is a spoken command")
            }
            if VoiceCommand.inlineInstruction(text, phrases: phrases) != nil {
                return Skip(code: "inline_instruction", described: "this carries an instruction of its own")
            }
        }
        if let wanted = step.app {
            // Fails closed. Without Accessibility, or on a path that never had
            // a window to read, there is no app — and "run it anyway" would run
            // a terminal-only stage in your editor, which is the one outcome
            // asking for `app:` was meant to prevent.
            guard let app else {
                return Skip(
                    code: "app_unknown",
                    described: "app \(wanted) cannot be checked — nothing was in front"
                )
            }
            do {
                if try !step.holds(wanted, subject: app.searchable, scope: scope) {
                    return Skip(
                        code: "app_mismatch",
                        described: "app \(wanted) did not match \(app.described)"
                    )
                }
            } catch {
                return broken("app", wanted, error, scope)
            }
        }
        do {
            if let unless = step.unless,
               try step.holds(unless, subject: text, scope: scope) {
                return Skip(
                    code: "unless_matched",
                    described: "unless \(unless) matched\(evidence(unless, scope))"
                )
            }
        } catch {
            return broken("unless", step.unless ?? "", error, scope)
        }
        do {
            if let when = step.when,
               try !step.holds(when, subject: text, scope: scope) {
                return Skip(
                    code: "when_unmatched",
                    described: "when \(when) did not match\(evidence(when, scope))"
                )
            }
        } catch {
            return broken("when", step.when ?? "", error, scope)
        }
        return nil
    }

    /// A condition that could not be answered at all.
    ///
    /// Skipping is the safe direction and the only one available: the question
    /// "should this stage run" has no answer, and running a stage on a condition
    /// nobody could evaluate is how a terminal-only rewrite ends up in an email.
    /// The transcript passes through untouched, which is what every other
    /// failure in this file does too.
    private static func broken(
        _ label: String, _ condition: String, _ error: Error, _ scope: Scope
    ) -> Skip {
        Skip(
            code: "condition_error",
            described: "\(label) \(condition) could not be answered — "
                + ((error as? Condition.Failure)?.message ?? error.localizedDescription)
        )
    }

    /// The values that decided an expression, appended to the reason it gives.
    ///
    /// Naming the condition was enough while a condition was a regex and the
    /// text was right there on the line above. An expression is not: "when
    /// code_identifiers.count == 0 did not match" leaves the one question you
    /// actually have unanswered, and the answer is already in the scope.
    private static func evidence(_ condition: String, _ scope: Scope) -> String {
        guard !Step.isPattern(condition) else { return "" }
        let read = Condition.roots(of: condition)
            .sorted()
            .compactMap { path in scope[path].map { "\(path) = \($0.described)" } }
        return read.isEmpty ? "" : " (\(read.joined(separator: ", ")))"
    }

    /// - Parameter progress: Called with a stage's `display:` as that stage
    ///   starts, for whatever is showing the wait. Only stages that wrote one
    ///   report, so the caller's own message stands through the rest: the
    ///   tables finish in microseconds, and a label that changed six times on
    ///   the way to a transcript would say less than one that never moved.
    func run(
        _ text: String, config: Config, allowPrompts: Bool = true, app: App? = nil,
        seed: Scope = Scope(), findings: Vocabulary.Outcome? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        await runCollectingScope(
            text, config: config, allowPrompts: allowPrompts, app: app,
            seed: seed, findings: findings, progress: progress
        ).text
    }

    /// The same run, handing back the variables as well as the sentence.
    ///
    /// Separate from `run` because almost nothing wants the scope — the app
    /// wants a string to type — and a caller that only needs the text should not
    /// have to say `.text` to get it. `--pipeline` and the case sets want both,
    /// and they are the reason the scope is reachable at all: a variable nothing
    /// can print is a variable nobody can debug.
    /// - Parameter findings: What the acoustic pass proposed, and the exact
    ///   text it measured those proposals against. Only the `vocabulary` stage
    ///   reads it, and it is handed over rather than published as a variable
    ///   because a `Range<String.Index>` cannot survive being turned into a
    ///   string and back — which is where four of the prototype's bugs lived
    ///   (F5, F9).
    func runCollectingScope(
        _ text: String, config: Config, allowPrompts: Bool = true, app: App? = nil,
        seed: Scope = Scope(), findings: Vocabulary.Outcome? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> (text: String, scope: Scope) {
        var output = text
        var scope = seed
        // Seeded here rather than by the caller so that every path through the
        // app agrees about what a condition can read. `--pipeline` and a live
        // dictation differ only in what they know, never in what they call it.
        scope.set("text", .string(output))
        if let app {
            scope.set("app", .string(app.name))
            scope.set("bundle_id", .string(app.bundleID))
        }
        // Only when the caller did not already resolve it. `Replacements.apply`
        // detects the language to choose the pipeline and seeds it on the way
        // in, so the live path costs nothing here; a caller that reaches this
        // type directly — `--eval` does — would otherwise leave `language`
        // absent from a condition and from a script's context. Absent is better
        // than wrong, and present-and-right is better than either.
        if scope["language"] == nil {
            scope.set("language", .string(Pipeline.forText(output, config: config).1))
        }
        // Same reason, for the acoustic pass. It runs inside transcription and
        // seeds these itself; every other way in — `--replace`, `--pipeline`,
        // a case set — has no audio and so seeds nothing, and a condition
        // reading `vocabulary.count` then fails the *whole* expression rather
        // than resolving to zero. `a || b` is not a rescue when `a` throws.
        if scope["vocabulary.count"] == nil {
            scope.set("vocabulary.count", .int(0))
            scope.set("vocabulary.changes", .string(""))
        }

        for step in steps {
            let named = step.transform.map { "\(step.stage.name) \($0)" } ?? step.stage.name
            let namespace = Pipeline.namespace(of: step)

            if let reason = Pipeline.skipReason(
                for: step, text: output, config: config,
                allowPrompts: allowPrompts, app: app, scope: scope
            ) {
                // Said out loud: a stage that silently does not run is
                // indistinguishable from one that ran and found nothing, and
                // only one of those is answerable by editing a condition.
                Log.write("pipeline: skipped \(named) — \(reason.described)")
                Trace.current?.recordSkip(named, code: reason.code, reason: reason.described)
                // `ran` and nothing else. A stage that did not run has no `ok`
                // and no `changed` to report, and inventing them would let
                // `grammar.ok` read true for a stage that never happened. The
                // way to ask is `grammar.ran && grammar.ok`, which is what `&&`
                // short-circuits for.
                scope.merge(["ran": .bool(false)], under: namespace)
                continue
            }
            // After the skip check, not before: a stage that is about to
            // decline should not put its name on screen first.
            if let label = step.transform
                .flatMap({ config.transform(named: $0) })?.displayLabel {
                progress?(label)
            }
            // Timed here rather than inside each kind of stage, so the number
            // covers the same span for a table, a script and a model call —
            // the three costs `AGENTS.md` asks you to choose between, finally
            // measured on your own sentences instead of quoted from a README.
            let before = output
            let started = CFAbsoluteTimeGetCurrent()
            let result = await apply(
                step, to: output, config: config, app: app, scope: scope, findings: findings
            )
            let seconds = CFAbsoluteTimeGetCurrent() - started
            output = result.text

            // `vocabulary.count` answers one question: was a vocabulary term
            // written into this transcript? Not "by which mechanism" — sound
            // and exact rules are both ways of getting the same term in, and a
            // caller asking whether to check the result does not care which
            // fired. The acoustic pass seeds its own count before the pipeline
            // starts; a rule whose target is a vocabulary term adds to it here.
            if step.stage == .replacements, case .string(let wrote)? = result.vars["changes"] {
                let known = Set(config.vocabulary.terms.keys)
                let hits = wrote.split(separator: ";").filter { pair in
                    guard let arrow = pair.range(of: "->") else { return false }
                    return known.contains(
                        pair[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                    )
                }.count
                if hits > 0 {
                    let before: Int
                    if case .int(let had)? = scope["vocabulary.count"] { before = had }
                    else { before = 0 }
                    scope.set("vocabulary.count", .int(before + hits))
                    if case .string(let had)? = scope["vocabulary.changes"], !had.isEmpty {
                        scope.set("vocabulary.changes", .string(had + "; " + wrote))
                    } else {
                        scope.set("vocabulary.changes", .string(wrote))
                    }
                }
            }

            // Derived, never claimed. `changed` is the comparison this loop just
            // made, and a stage cannot get it wrong by forgetting to report it
            // or by reporting it about the wrong string. Written *before* the
            // stage's own contribution so that a stage which insists on
            // publishing `ms` is allowed to — nothing here is worth overruling a
            // script that knows better about itself.
            scope.merge([
                "ran": .bool(true),
                "ok": .bool(result.vars["ok"] != .bool(false)),
                "changed": .bool(output != before),
                "ms": .double((seconds * 1000).rounded()),
            ], under: namespace)
            scope.merge(result.vars, under: namespace)
            // The one bare name that moves. A condition reads the text as it
            // stands at that point in the pipeline — that has always been true
            // of a `when:` pattern, and an expression asking `text.matches(…)`
            // has to mean the same thing.
            scope.set("text", .string(output))

            Trace.current?.recordStage(
                named, before: before, after: output, seconds: seconds,
                vars: scope.namespace(namespace)
            )
        }
        return (output, scope)
    }

    /// Which name a stage's facts are filed under.
    ///
    /// The transform's name for a `transform` stage, the stage's own name for
    /// everything else — so a condition says `code_identifiers.count` rather
    /// than `transform.count`, and two transforms in one pipeline do not share
    /// a namespace. Two steps naming the *same* transform do share one, and the
    /// later run wins; that is the reading a list executed top to bottom
    /// invites, and refusing it would rule out running `replacements` both
    /// before and after a rewrite.
    static func namespace(of step: Step) -> String {
        step.transform ?? step.stage.name
    }

    private func apply(
        _ step: Step, to text: String, config: Config, app: App?, scope: Scope,
        findings: Vocabulary.Outcome? = nil
    ) async -> StageResult {
        switch step.stage {
        case .replacements:
            // Both tables. `config.yaml` holds the patterns and deletions a
            // person wrote; `vocabulary.yaml` holds the names the app learnt.
            // One pass, so a rule behaves the same whichever file it came from.
            let done = Replacements.exact(
                to: text, rules: config.transcription.rules + config.vocabularyRules
            )
            // `changes` as well as `count`, so a later stage can judge what
            // this one did. A stage handed only the finished sentence cannot
            // tell which words were rewritten, and guessing is how a judge
            // starts reverting things nobody changed.
            return StageResult(text: done.text, vars: [
                "count": .int(done.count),
                "changes": .string(done.changes),
            ])
        case .fuzzy:
            // From the rules, not from the table's keys. Fuzzy matching
            // compares spellings, so a target is only a candidate if it is one
            // — `$1.$2` is a template, not a word anything could sound like,
            // and offering it as one puts a string in the list that every
            // comparison has to lose to. `isFuzzyCandidate` was written for
            // this and had never been wired to anything.
            let targets = Set(
                config.transcription.rules.filter(\.isFuzzyCandidate).map(\.replacement)
            )
            return StageResult(text: Replacements.applyFuzzy(to: text, targets: Array(targets)))
        case .numbers:
            let done = Numbers.read(text, languages: config.transcription.languages)
            return StageResult(text: done.text, vars: ["language": .string(done.language)])
        case .context:
            return await readContext(on: text)
        case .vocabulary:
            return await judgeVocabulary(step, on: text, config: config, scope: scope,
                                         findings: findings)
        case .transform:
            return await runTransform(step, on: text, config: config, scope: scope)
        }
    }

    /// The screen behind the field, as variables. Never as text.
    ///
    /// This is the one stage that returns its input untouched by construction
    /// rather than by outcome, so `context.changed` is false on every run and
    /// means it. A stage that could put the screen into the transcript would be
    /// a stage that could paste somebody's terminal into their chat message.
    ///
    /// The screen is not read here. It was read when the hotkey went down, and
    /// this hands on what `Context.capturePress` stored.
    ///
    /// That is the whole point of the stage's shape. By the time this runs there
    /// has been a transcription and possibly a model call, and focus may be in
    /// another pane — so a read here answers "what is on screen now" when the
    /// question is "what were you looking at when you decided to say this".
    /// Those are the same screen most of the time and the wrong one exactly when
    /// it matters.
    ///
    /// It also means this stage does no accessibility work at all, which is why
    /// there is no thread argument to have. An earlier version read here and hopped
    /// to the main actor to do it; that deadlocked, because `--pipeline` drives
    /// this with a semaphore the main thread is sitting in.
    ///
    /// Declining is normal and is not an error: no permission, the wrong app in
    /// front, a surface that is not a terminal, or no press at all — which is
    /// every run under `--pipeline`, and every entry point that is not the
    /// hotkey. Each publishes `ok: false` and the reason, because "read nothing"
    /// and "was not allowed to look" are different answers and a condition
    /// should be able to tell them apart.
    private func readContext(on text: String) async -> StageResult {
        switch Context.pressCapture?.outcome ?? .failure(.noPress) {
        case .failure(let why):
            Log.write("pipeline: context declined — \(why.rawValue)")
            // The same keys a successful read publishes, emptied, plus the
            // reason. Not fewer: a condition is written once and has to hold on
            // the runs where nothing could be read, which are most of them — and
            // `context.text` that is absent throws where `context.text` that is
            // empty is simply true. Empty is also the honest answer. Nothing was
            // on screen as far as this stage is concerned, and `ok` and
            // `declined` are there to say whether that was a screen or a refusal.
            return StageResult(text: text, vars: [
                "ok": .bool(false),
                "declined": .string(why.rawValue),
                "text": .string(""),
                "chars": .int(0),
                "lines": .int(0),
                "truncated": .bool(false),
            ])
        case .success(let capture):
            // The whole capture goes to the log, not a count of it. The point of
            // this stage is to find out what is worth reading off a screen, and
            // that judgement cannot be made from "1840 chars". Worth knowing
            // before turning it on: while it is on, the log holds what was on
            // screen when you dictated.
            Log.write("pipeline: context read \(capture.chars) chars, \(capture.lines) line(s)"
                + (capture.truncated ? " (truncated to the last \(Context.maxChars))" : ""))
            for row in capture.text.components(separatedBy: "\n") {
                Log.write("    | \(row)")
            }
            return StageResult(text: text, vars: [
                "text": .string(capture.text),
                "chars": .int(capture.chars),
                "lines": .int(capture.lines),
                "truncated": .bool(capture.truncated),
            ])
        }
    }

    /// The names the acoustic pass was unsure about, put to a model as a menu.
    ///
    /// Fails closed at every step. The transcript that arrives here is what
    /// ships if anything at all goes wrong — no prompt file, no proposals, too
    /// many slots, Ollama down, an unreadable reply. Losing the judge costs a
    /// name; losing the sentence costs the sentence.
    ///
    /// The mechanics are in `VocabularyJudge`. This is the wiring: where the
    /// prompt file is, what the model is, and which variables come back.
    private func judgeVocabulary(
        _ step: Step, on text: String, config: Config, scope: Scope,
        findings: Vocabulary.Outcome?
    ) async -> StageResult {
        func declined(_ why: String, _ vars: [String: Scope.Value] = [:]) -> StageResult {
            Log.write("pipeline: vocabulary — \(why)")
            return StageResult(text: text, vars: vars.merging(["ok": .bool(false)]) { a, _ in a })
        }
        guard config.llm.enabled else { return declined("llm.enabled is false") }
        guard let named = step.prompt, !named.isEmpty else {
            return declined("no prompt file named — write `- vocabulary: <file.md>`")
        }
        guard let prompt = config.promptFile(named) else {
            return declined("cannot read the prompt file \(named)")
        }

        let caps = step.caps ?? VocabularyJudge.Caps.standard
        // Both sources. The acoustic pass proposes with positions; a
        // `replacements` rule publishes none, so its substitutions are found by
        // searching for the term and told apart from the terms the decoder
        // already had by comparing against the text the pass returned.
        var rules = ""
        if case .string(let wrote)? = scope["replacements.changes"] { rules = wrote }
        let parts = VocabularyJudge.acousticParts(
            findings?.proposals ?? [], in: text, measuredOn: findings?.text ?? text
        ) + VocabularyJudge.ruleParts(rules, in: text, before: findings?.text)

        let slots = VocabularyJudge.slots(in: text, from: parts, caps: caps)
        // Logged on every run, not only when the count is fatal. `max_slots` is
        // the cliff this stage falls off — one slot over and the whole menu is
        // declined — so the distance to it has to be measurable before a change
        // that widens what fires, not inferred afterwards from the clips that
        // broke.
        Log.write("vocabulary judge: \(slots.count) slot(s) from \(parts.count) proposal(s)")
        guard !slots.isEmpty else {
            return StageResult(text: text, vars: ["asked": .int(0), "slots": .int(0)])
        }
        // Too many uncertain words to enumerate. Keeping what the decoder wrote
        // is the safe answer, and it is logged rather than silent.
        guard slots.count <= caps.slots else {
            return declined("\(slots.count) slots > \(caps.slots); kept as decoded",
                            ["asked": .int(0), "slots": .int(slots.count)])
        }

        let built = VocabularyJudge.readings(in: text, from: slots, caps: caps)
        let sentences = built.sentences
        // Trimming a slot cannot always get under the cap — it stops at two
        // readings a slot — so the menu is cut instead. Said out loud: the
        // decoder's own reading is still first, so the cost is a correction
        // never offered rather than a wrong one written.
        if built.truncated {
            Log.write("pipeline: vocabulary — \(slots.count) slots allow more readings than"
                + " the menu may hold; cut at \(sentences.count)")
        }
        guard sentences.count > 1 else {
            return StageResult(text: text, vars: [
                "asked": .int(sentences.count), "slots": .int(slots.count),
            ])
        }
        let terms = Array(Set(slots.flatMap(\.terms))).sorted().joined(separator: ", ")
        let system = prompt.replacingOccurrences(of: "{terms}", with: terms)
        let scores = VocabularyJudge.scoreBlock(findings?.proposals ?? [])
        VocabularyJudge.dump(system: system, sentences: sentences, scores: scores)

        let reply: String
        do {
            reply = try await LocalLLM.complete(
                system: system,
                user: VocabularyJudge.menu(sentences) + scores + "\n\nWhich letter?",
                json: false,
                // A letter and whatever the model wraps it in. Anything longer
                // is a model explaining itself, which this shape does not read.
                maxTokens: 8,
                config: LocalLLM.Config(
                    endpoint: config.llm.endpoint, model: config.llm.model,
                    timeout: config.llm.timeoutSeconds, keepLoaded: config.llm.keepLoaded
                )
            )
        } catch {
            return declined("\(error.localizedDescription); kept as decoded",
                            ["asked": .int(sentences.count), "slots": .int(slots.count)])
        }
        guard let pick = VocabularyJudge.chosen(reply, of: sentences.count) else {
            return declined("the reply named no option (\"\(reply)\"); kept as decoded",
                            ["asked": .int(sentences.count), "slots": .int(slots.count),
                             "reply": .string(reply)])
        }

        // What the judge left alone, in the words it left. "Reverted" was the
        // word for this while the pass substituted first; it proposes now, so a
        // slot that keeps its first reading was never changed to begin with.
        let kept = zip(built.slots, built.choices[pick])
            .filter { $0.1 == 0 }
            .map { $0.0.options[0] }
        let chosen = sentences[pick]
        if chosen != text {
            Log.write("pipeline: vocabulary rewrote the transcript")
            Log.write("    before: \(text)")
            Log.write("    after:  \(chosen)")
        }
        return StageResult(text: chosen, vars: [
            "asked": .int(sentences.count),
            "slots": .int(slots.count),
            "kept_as_decoded": .string(kept.joined(separator: "; ")),
            "judged": .string(chosen),
            "reply": .string(reply.trimmingCharacters(in: .whitespacesAndNewlines)),
            "model": .string(config.llm.model),
        ])
    }

    /// Whichever kind of transform the step named.
    ///
    /// A missing one returns the transcript rather than emptying it, same as
    /// every other way this stage declines — the name may be a typo, and
    /// `--check-config` is where that gets said.
    private func runTransform(
        _ step: Step, on text: String, config: Config, scope: Scope
    ) async -> StageResult {
        guard let name = step.transform else {
            Log.write("pipeline: a transform stage names no transform; skipped")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }
        guard let transform = config.transform(named: name) else {
            Log.write("pipeline: no transform named \"\(name)\"; skipped")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }
        switch transform.body {
        case .prompt:
            return await runPrompt(step, named: name, on: text, config: config, scope: scope)
        case .replace:
            // Exact and free, so there is nothing to guard and nothing to
            // report beyond what the table did — the log line is the same one
            // `replacements` writes, with the name that asked for it.
            let done = Replacements.exact(to: text, rules: transform.rules)
            if done.text != text {
                Log.write("pipeline: transform \(name) rewrote the transcript")
                Log.write("    before: \(text)")
                Log.write("    after:  \(done.text)")
            }
            return StageResult(text: done.text, vars: ["count": .int(done.count)])
        case .command(let command):
            // Someone else's program, so this is the second stage that can
            // fail and the second that must not fail loudly. `run` returns nil
            // for every way it can go wrong, and nil means keep the
            // transcript. Logged either way: a stage you wrote yourself is
            // exactly the one whose before and after you want on the record.
            let outcome = CommandRunner.run(
                command, on: text, in: transform.folder, seconds: transform.timeout,
                structured: transform.returnsJSON,
                context: transform.returnsJSON ? CommandRunner.Context(scope: scope) : nil
            )
            guard let result = outcome else {
                return StageResult(text: text, vars: ["ok": .bool(false)])
            }
            // A structured body that returned no `text` key has said "I did not
            // touch the sentence", which is not the same as returning the same
            // string — but it lands in the same place, and `changed` is derived
            // from the comparison either way.
            let after = result.text ?? text
            if after != text {
                Log.write("pipeline: transform \(name) rewrote the transcript")
                Log.write("    before: \(text)")
                Log.write("    after:  \(after)")
            }
            return StageResult(text: after, vars: result.vars)
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
    private func runPrompt(
        _ step: Step, named name: String, on text: String, config: Config, scope: Scope
    ) async -> StageResult {
        guard config.llm.enabled else {
            Log.write("pipeline: skipped prompt \(name) — llm.enabled is false")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }
        guard let prompt = config.transform(named: name)?.asPrompt else {
            Log.write("pipeline: no prompt named \"\(name)\"; skipped")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }

        do {
            let result = try await PromptRunner.run(
                prompt: prompt,
                // No spoken instruction exists on this path — a pipeline prompt
                // is not something anybody asked for out loud. `{{instruction}}`
                // in a pipeline prompt therefore resolves to nothing, and takes
                // its paragraph with it.
                instruction: "",
                text: text,
                // What every stage before this one published. A prompt reads it
                // by the same names a condition does.
                scope: scope,
                config: LocalLLM.Config(
                    endpoint: config.llm.endpoint,
                    model: config.llm.model,
                    timeout: config.llm.timeoutSeconds,
                    keepLoaded: config.llm.keepLoaded
                )
            )
            guard !result.isEmpty else {
                Log.write("pipeline: prompt \(name) returned nothing; kept the transcript")
                return StageResult(text: text, vars: ["ok": .bool(false)])
            }
            if result != text {
                Log.write("pipeline: prompt \(name) rewrote the transcript")
                Log.write("    before: \(text)")
                Log.write("    after:  \(result)")
            }
            // Which model wrote this. A prompt stage is the one whose output
            // nobody sees happen, and "was that the model I think it was" is
            // the first question when its answers change shape between two
            // runs — the same question `Trace` logs `asr.model` to answer.
            return StageResult(text: result, vars: ["model": .string(config.llm.model)])
        } catch {
            Log.write("pipeline: prompt \(name) failed (\(error.localizedDescription));"
                + " kept the transcript")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }
    }
}
