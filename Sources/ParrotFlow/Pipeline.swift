import Foundation

/// What happens to a transcript between the model finishing and the text
/// landing in your editor.
///
/// It was always a pipeline — exact replacements, then fuzzy ones, then spoken
/// numbers — but the order lived in one function and each step was switched by
/// a boolean of its own. That works until you want a fourth step, or one step
/// gated on something a flag cannot express.
///
/// So the order becomes data: one list of stages, read from the config. This
/// type is the list and the running of it, and nothing else. Every stage is
/// `String -> String` and already had its own validation set before it was a
/// stage; what is new here is only that they are named, ordered and selected
/// from outside the code.
///
/// The language a transcript is in is seeded into the scope here, so a step
/// can say `when: language == "fr"`. It is *not* handed down to the stages:
/// `numbers` keeps its own resolution, and has to. Its rule is not "read this
/// language" but "try the detected one, then the others, and let a candidate
/// win only on real evidence" — the guard that stops French reading the
/// "cents" in "I have 99 cents" as hundreds. Collapsing that to one language
/// here would quietly delete it.
struct Pipeline: Equatable, Codable {

    /// One step. Deliberately not a closure: a stage has to be nameable in a
    /// config file, comparable in a test, and printable in a log, and a
    /// function value is none of those.
    /// The raw value is the name written in the config, so the two cannot
    /// drift apart — a stage that cannot be spelled is a stage nobody can ask
    /// for.
    enum Stage: String, Equatable, Codable, CaseIterable {
        /// What the speaker meant, where the decoder wrote what it heard.
        ///
        /// Today that is the marks a pause put in: a period or a question mark
        /// mid-sentence, and the capital after it — see `SentenceJoin`.
        /// `marks:`, `capitals:` and `pause:` on the step say how far it
        /// reaches. English only, and it refuses every other language itself.
        ///
        /// First in the list, because it reads the decoder's own words: the
        /// pause gate lines the text up against the token timings, and a stage
        /// above it that rewrites a word breaks that alignment.
        case interpret
        /// Names: matched from `vocabulary.yaml`, then each match settled
        /// against the sentence it stands in. `near_misses:`, `by_sound:` and
        /// `gate:` on the step say how far it reaches — see `Step`.
        ///
        /// One stage because it was always one algorithm. It was written as
        /// three — `replacements` wrote the exact matches, `fuzzy` caught the
        /// near ones, `vocabulary` judged them — and the order they had to run
        /// in was enforced by hand, because the three were never independent.
        /// Spoken numbers as digits, in the language its own pass resolves.
        case numbers
        /// What is on screen around the field, published as `context.*` and
        /// never written into the transcript. Terminals only — see `Context`.
        case context
        /// What is already *in* the field, and where the caret is, published as
        /// `input.*` and never written into the transcript. Works in every
        /// surface, which is why it is not part of `context` — see `InputBox`.
        case input
        /// Every substitution the vocabulary pass made, settled against the
        /// sentence it stands in — see `VocabularyJudge` and `SentenceGate`.
        /// The pipeline entry is `- vocabulary`. It calls no model.
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
        /// that edits text moves them (F10). `interpret` is the exception, and
        /// `vocabularyOrderProblems` is where that is written down.
        var editsText: Bool { self != .context && self != .input && self != .vocabulary }

        /// Whether it can be in a default nobody wrote.
        ///
        /// `transform` cannot: it needs a name, and there is no transform every
        /// install is guaranteed to have. `vocabulary` cannot either, for the
        /// same reason — it names a prompt file.
        ///
        /// `context` cannot, for a different and stronger reason. It reads the
        /// screen. Turning that on for everybody who never wrote a `pipeline:`
        /// block would be a silent change to what the app looks at, which is the
        /// one kind of change that has to be asked for by name.
        var isAutomatic: Bool {
            self != .transform && self != .context && self != .input
                && self != .vocabulary
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
        /// The prompt file a `vocabulary` stage used to ask with.
        ///
        /// Read only so `validate` can refuse it by name. There is no prompt
        /// and no model in that stage, and nothing else looks at this.
        var prompt: String?
        /// How many places one sentence may offer — see `VocabularyJudge.Caps`.
        /// Absent on every other stage.
        var caps: VocabularyJudge.Caps?
        /// Whether a `heard:` rendering also matches one edit away. Absent
        /// means true.
        ///
        /// Written `near_misses:`. It was `fuzzy:`, beside a *stage* also
        /// called `fuzzy` that did something else entirely — that one matched
        /// the text against the rule table and rewrote it, and never saw a
        /// vocabulary rendering at all. One word, two mechanisms, and the
        /// stage is gone now.
        ///
        /// Optional rather than defaulted so that "not written" and "written
        /// false" stay tellable apart — the seeded config writes the key only
        /// when it is off.
        ///
        /// Not the `fuzzy` *stage*, which is a different mechanism: that one
        /// matches the text against rule replacements after the exact pass,
        /// and never sees a vocabulary rendering at all.
        var nearMisses: Bool?
        /// Written `by_sound:`. Whether words that *sound* like a term are
        /// offered as well as words spelled like one — see
        /// `VocabularyJudge.phonemeParts`.
        ///
        /// Its own switch rather than part of `near_misses:`. The two reach
        /// different words (`pressed` by sound, `Praise's` by spelling), they
        /// have separate floors, and this one needs espeak-ng on the machine
        /// while the other needs nothing. Turning one off to measure the other
        /// is the first thing anybody will want.
        ///
        /// Optional for the reason `nearMisses` is: "not written" and "written
        /// false" have to stay tellable apart.
        var bySound: Bool?
        /// Written `gate:`. Whether the two word lists and the slot's part of
        /// speech may settle a proposal — see `VocabularyJudge.settle`.
        ///
        /// `gate: false` leaves every proposal to the sentence gate and to
        /// whatever arrived, which is what the gate was measured against and
        /// the only way to measure it again.
        var gate: Bool?
        /// Written `slot_gate:`. Whether anything reads the mmBERT slot — the
        /// part of speech the spot wants, in `SlotGate`, and the ten words it
        /// expects there, in `SlotReference`. Absent means true.
        ///
        /// One switch for both because they are one model, and the promise the
        /// switch makes is that `false` downloads nothing. Each half takes the
        /// path it already has on a machine the 269 MB is not on: the lexical
        /// gate settles what the word lists settle and asks nothing more, and
        /// the sentence gate is left to the portrait alone.
        var slotGate: Bool?
        /// Written `portrait:`. Whether a term's own sentences and its
        /// counter-examples may settle a proposal — see `TermPortrait`. Absent
        /// means true.
        ///
        /// `false` takes the path a term with too few uses already has: the
        /// portrait says nothing, and the slot's refusal is all that can speak.
        var portrait: Bool?
        /// Written `lowercase_refused:`. Whether a glued span the sentence
        /// refuses is written back in lowercase instead of as heard. Absent
        /// means true.
        ///
        /// `false` puts the span back exactly as the decoder wrote it, which
        /// is what every other refusal in this stage does.
        var lowercaseRefused: Bool?
        /// Written `slot_floor:`. How far the heard word must win by before
        /// `SlotReference` refuses the rewrite. A language it does not name
        /// keeps the built-in value for that language — see
        /// `Transcription.slotFloor(for:on:)`.
        var slotFloor: SlotFloor?
        /// `marks:` on an `interpret` step. What a boundary can be written
        /// with. Absent takes the built-in set for the language.
        ///
        /// One list, two jobs. The sentence enders in it — `.` and `?` — are
        /// where a boundary is looked for. Everything else in it — the comma —
        /// is a reading tried at every boundary. So a boundary is read three
        /// ways: the mark it carries, the comma, and no mark at all. Drop `?`
        /// from the list and question marks stop being scanned.
        ///
        /// There is no threshold; the reading the model scores highest is the
        /// one that is written. `;` and `:` were measured and never changed a
        /// decision in English, so they are not in the default.
        var marks: [String]?
        /// `capitals:` on an `interpret` step. Whether a capital with no mark
        /// in front of it is read as a boundary too. Absent means true.
        var capitals: Bool?
        /// `pause:` on an `interpret` step. Seconds of silence a bare capital
        /// needs in front of it before it is read. Zero or less reads every
        /// one. Absent means `SentenceJoin.paused`.
        var pause: Double?
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

        /// What `slot_floor:` said, in either spelling.
        ///
        ///     slot_floor: 0.20                 every language
        ///     slot_floor: {en: 0.20, fr: 0.30} one at a time
        ///
        /// A language the map does not name keeps its built-in floor.
        struct SlotFloor: Equatable, Codable {
            var everyLanguage: Double?
            var byLanguage: [String: Double] = [:]

            func value(for language: String) -> Double? {
                byLanguage[language] ?? everyLanguage
            }
        }

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
    /// An empty list is not the same as no list. `pipeline: []` is a choice and
    /// runs nothing; a missing `pipeline:` is silence and runs everything.
    static let everything = Pipeline(
        steps: Stage.allCases.filter(\.isAutomatic).map { Step(stage: $0) }
    )

    /// The pipeline the config names, or `everything` when it names none.
    static func resolved(config: Config) -> Pipeline {
        config.transcription.pipeline ?? everything
    }

    /// The language this text was judged to be in.
    ///
    /// Skipped entirely when there is nothing to choose between, which is the
    /// common case and saves the recogniser a call.
    static func language(of text: String, config: Config) -> String {
        let languages = config.transcription.languages
        guard languages.count > 1 else { return languages.first ?? "en" }
        return DictationLanguage.detect(
            text, allowed: languages, fallback: languages.first ?? "en"
        )
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
            // The prompt is compiled in. A config still naming a file is
            // refused rather than warned about: a warning leaves a filename in
            // a config doing nothing, and the person who edits that file and
            // sees the judge behave exactly as before has no way to find out
            // why. Refusing says it once, at load, where they typed it.
            if let named = step.prompt, !named.isEmpty {
                problems.append("pipeline: `- vocabulary: \(named)` names a prompt file."
                    + " The prompt is part of the app now — a wording is right or wrong"
                    + " against a measurement, not a matter of taste. Delete the filename"
                    + " and write `- vocabulary`")
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
        return problems
    }

    /// Stages that move the words `vocabulary` is about to talk about.
    ///
    /// The judge is handed spans the acoustic pass measured on the transcript
    /// as the decoder produced it. A stage that rewrites text moves them, and
    /// the stage then has to re-anchor by searching for the words — which is
    /// the mechanism that put the menu on the wrong `Versailles` (F3, F10).
    ///
    /// Nothing that rewrites the transcript may run above it, except
    /// `interpret` — see below.
    ///
    /// The stage reads spans the acoustic pass measured before the pipeline
    /// started, and any edit above it moves them (F10). The exact pass used to
    /// be an exception too, because it ran as a separate `replacements` stage
    /// and the judge needs the rules to have fired; it is inside this stage
    /// now.
    private func vocabularyOrderProblems() -> [String] {
        guard let judge = stages.firstIndex(of: .vocabulary) else { return [] }
        // `interpret` is the exception. It ran above the whole pipeline until
        // it became a step, so it has always been above this one, and it takes
        // a mark out rather than rewriting a word.
        let above = steps[..<judge]
            .filter { $0.stage.editsText && $0.stage != .interpret }
            .map { Pipeline.namespace(of: $0) }
        guard !above.isEmpty else { return [] }
        return ["vocabulary runs after \(above.joined(separator: ", ")), which rewrite the"
            + " transcript — the spans it was given no longer point at the same words."
            + " Put it above everything that edits text"]
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
        seed: Scope = Scope(), words: [Trace.Word] = [],
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        await runCollectingScope(
            text, config: config, allowPrompts: allowPrompts, app: app,
            seed: seed, words: words, progress: progress
        ).text
    }

    /// The same run, handing back the variables as well as the sentence.
    ///
    /// Separate from `run` because almost nothing wants the scope — the app
    /// wants a string to type — and a caller that only needs the text should not
    /// have to say `.text` to get it. `--pipeline` and the case sets want both,
    /// and they are the reason the scope is reachable at all: a variable nothing
    /// can print is a variable nobody can debug.
    /// `words` are the decoder's own, for the `interpret` step's pause gate.
    /// Every other way in has no audio and hands over none, and the gate then
    /// stands down rather than guessing.
    func runCollectingScope(
        _ text: String, config: Config, allowPrompts: Bool = true, app: App? = nil,
        seed: Scope = Scope(), words: [Trace.Word] = [],
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
            scope.set("language", .string(Pipeline.language(of: output, config: config)))
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
        // The named lists, so a transform that is a program reads the same
        // words a `replace:` pattern writes as `{{determiners}}`. Under one
        // namespace, so a script asks `ctx["vars"]["lists"]["determiners"]`.
        for (name, value) in config.listVariables {
            scope.set("lists.\(name)", value)
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
                step, to: output, config: config, app: app, scope: scope, words: words
            )
            let seconds = CFAbsoluteTimeGetCurrent() - started
            output = result.text

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
        words: [Trace.Word]
    ) async -> StageResult {
        switch step.stage {
        case .interpret:
            return await interpret(step, on: text, config: config, words: words)
        case .numbers:
            let done = Numbers.read(text, languages: config.transcription.languages)
            return StageResult(text: done.text, vars: ["language": .string(done.language)])
        case .context:
            return await readContext(on: text)
        case .input:
            return readInputBox(on: text, scope: scope)
        case .vocabulary:
            return await settleVocabulary(step, on: text, config: config, scope: scope,
                                        )
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

    /// The field's own contents and the caret, as variables. Never as text.
    ///
    /// Like `context` this returns its input untouched, and for the same
    /// reason: a stage that could put the field into the transcript could paste
    /// what you already typed back on top of itself.
    ///
    /// The box is not read here. It was read when the hotkey went down — see
    /// `InputBox.capturePress` — because by then focus may have moved.
    ///
    /// The capture is fetched by press run, seeded as `press.run`. Dictations
    /// overlap, and "the box you were typing in" is a question about one press.
    /// No run in scope means no press at all, which is every entry point that
    /// is not the hotkey — `--pipeline` above all.
    ///
    /// `before`, `selection`, `after` and `appending` are absent rather than
    /// empty where the surface publishes no caret, which is every terminal.
    /// Absent throws in a condition and that is the point: `when: input.appending`
    /// should fail loudly on a surface that cannot answer it, not read as "no".
    private func readInputBox(on text: String, scope: Scope) -> StageResult {
        let capture: Result<InputBox.Capture, InputBox.Declined> = {
            guard case .int(let run)? = scope["press.run"],
                  let press = InputBox.capture(for: run) else { return .failure(.noPress) }
            return press.outcome
        }()
        switch capture {
        case .failure(let why):
            Log.write("pipeline: input declined — \(why.rawValue)")
            // The same keys a successful read publishes, emptied, plus the
            // reason. A condition is written once and has to hold on the runs
            // where nothing could be read.
            return StageResult(text: text, vars: [
                "ok": .bool(false),
                "declined": .string(why.rawValue),
                "text": .string(""),
                "chars": .int(0),
                "total": .int(0),
                "truncated": .bool(false),
            ])
        case .success(let capture):
            let placement = capture.before == nil ? "caret unknown"
                : (capture.appending == true ? "appending" : "inserting")
            Log.write("pipeline: input read \(capture.chars) of \(capture.total) chars, "
                + placement + (capture.truncated ? ", truncated" : ""))
            // Directly above whatever `join` then logs, because the two lines
            // only answer the question together: which rule fired, and what it
            // read to pick that one.
            if let neighbourhood = capture.neighbourhood {
                Log.write("    caret: \(neighbourhood)")
            }
            var vars: [String: Scope.Value] = [
                "chars": .int(capture.chars),
                "total": .int(capture.total),
                "truncated": .bool(capture.truncated),
            ]
            if let before = capture.before { vars["before"] = .string(before) }
            if let selection = capture.selection { vars["selection"] = .string(selection) }
            if let after = capture.after { vars["after"] = .string(after) }
            if let whole = capture.text { vars["text"] = .string(whole) }
            if let appending = capture.appending { vars["appending"] = .bool(appending) }
            return StageResult(text: text, vars: vars)
        }
    }

    /// The marks a pause put in, taken out again — see `SentenceJoin`.
    ///
    /// Fails open. No model on disk, a model not in memory yet, a language
    /// that is not English: the transcript arrives as it was, and the step
    /// still publishes `ran: true` with `count: 0`. A boundary left as decoded
    /// is a worse transcript; an error here would cost the sentence.
    private func interpret(
        _ step: Step, on text: String, config: Config, words: [Trace.Word]
    ) async -> StageResult {
        guard #available(macOS 14, *) else {
            return StageResult(text: text, vars: ["count": .int(0)])
        }
        let language = Pipeline.language(of: text, config: config)
        let outcome = await SentenceJoin.shared.apply(
            to: text, config: config,
            marks: step.marks ?? config.transcription.marks(for: language),
            capitals: step.capitals ?? true,
            pause: step.pause ?? SentenceJoin.paused,
            words: words
        )
        return StageResult(text: outcome.text, vars: ["count": .int(outcome.count(.join))])
    }

    /// Every substitution the vocabulary pass made, settled where it stands.
    ///
    /// Fails closed at every step. The transcript that arrives here is what
    /// ships if anything at all goes wrong — no proposals, a word list that is
    /// not loaded, a sentence model that is not on disk. Losing a gate costs a
    /// name; losing the sentence costs the sentence.
    ///
    /// **Nothing here calls a model.** Every substitution used to be put to a
    /// local model, one KEEP or REVERT each, at about 900 ms a dictation. What
    /// decides now is the two word lists, the slot's part of speech, and the
    /// two tests that read the sentence — see `VocabularyJudge.settle` and
    /// `SentenceGate`. Every place they leave open keeps what arrived.
    ///
    /// The mechanics are in `VocabularyJudge`. This is the wiring: which
    /// substitutions are gathered, which gates run, and which variables come
    /// back.
    private func settleVocabulary(
        _ step: Step, on text: String, config: Config, scope: Scope,
    ) async -> StageResult {
        // The exact pass, first and inside this stage. It was a `replacements`
        // stage of its own and had to be listed above this one by hand; a
        // rule's substitution is one of the readings this stage weighs, so the
        // rules must already have fired. One stage, and the order is no longer
        // something a config can get wrong.
        let handed = text
        let exact = Replacements.exact(
            to: text, rules: config.vocabularyRules, expand: config.expanded
        )
        let text = exact.text

        // What the exact pass did, published whatever the gates decide
        // afterwards. These were `replacements.*` while that was a stage of its
        // own; a later stage reading them cares that a term was written, not
        // which half of this stage wrote it.
        // Raised by the near-miss pass below, which reaches terms an exact
        // rule cannot. `when: vocabulary.count > 0` is what keeps a later stage
        // off a dictation with no name in it, so a term that arrives only by a
        // near miss has to raise this or that stage never runs.
        var nearMisses = 0
        var bySound = 0
        // Where this stage's time goes, split at its two model calls. The
        // stage's own `ms` is one number for all of it, so it cannot tell a
        // pronunciation the model has never been asked for from a term
        // portrait being rebuilt. Those are the two things that put a
        // dictation past a second here.
        var soundSeconds = 0.0
        var gateSeconds = 0.0
        func result(_ text: String, _ vars: [String: Scope.Value]) -> StageResult {
            let wrote: [String: Scope.Value] = [
                "count": .int(exact.count + nearMisses + bySound),
                "changes": .string(exact.changes),
                "before": .string(handed),
                "protected": .string(exact.protected),
                "sound_ms": .int(Int((soundSeconds * 1000).rounded())),
                "gate_ms": .int(Int((gateSeconds * 1000).rounded())),
            ]
            return StageResult(text: text, vars: wrote.merging(vars) { _, new in new })
        }

        let caps = step.caps ?? VocabularyJudge.Caps.standard
        // Both sources. The acoustic pass proposes with positions; a
        // `replacements` rule publishes none, so its substitutions are found by
        // searching for the term and told apart from the terms the decoder
        // already had by comparing against the text that stage was handed.
        //
        // From `replacements`, which is the only stage that may edit text
        // above `vocabulary`, so the text a rule was measured against is the
        // text this stage was handed.
        let rules = exact.changes
        let beforeRules: String? = handed
        var parts = VocabularyJudge.ruleParts(rules, in: text, before: beforeRules)

        // The near misses an exact rule cannot reach. On by default: an exact
        // rule is the narrowest route to a term, and `Praisy`'s list holding
        // `Praises` while the decoder wrote `Praise's` is a name lost for one
        // apostrophe. `fuzzy: false` on the stage turns it off and leaves
        // matching exact.
        //
        // Nothing is written here. A near miss becomes one more place for the
        // gates to settle, and a place none of them settles keeps the word
        // that was heard — see `VocabularyJudge.fuzzyEdits` for what it fires
        // on and what that cost over this speaker's archive.
        if step.nearMisses ?? true {
            let reached = VocabularyJudge.fuzzyParts(
                in: text, rules: config.vocabularyRules, claimed: parts
            )
            nearMisses = reached.count
            parts += reached
        }

        // The words no spelling reaches. `geler` is 0.60 from `Gelar` by
        // letters and identical to it by sound, and so are `Ghost E`,
        // `cloth code` and `eye brands`. Off for a French dictation: espeak's
        // English letter-to-sound answers for French words, and the answer is
        // noise.
        //
        // Nothing is written here either. The floor is 0.85 and it was
        // measured over 20891 dictations — see `phonemeParts` for what fires
        // and what it costs.
        if step.bySound ?? true, Pipeline.language(of: text, config: config) == "en" {
            let askedAt = Date()
            let heard = await VocabularyJudge.phonemeParts(
                in: text, sounds: config.vocabularySounds, voice: "en-us",
                language: "en", floor: config.vocabulary.soundBelow, claimed: parts
            )
            soundSeconds = Date().timeIntervalSince(askedAt)
            bySound = heard.count
            parts += heard
        }

        let slots = VocabularyJudge.slots(in: text, from: parts, caps: caps)
        // Two numbers on every run. How many places one sentence offers is the
        // measure of how much this stage is being asked to decide, so it has
        // to be readable before a change that widens what fires, not inferred
        // afterwards from the clips that broke.
        //
        // Counts only. **Which words** is behind `PARROTFLOW_JUDGE_DUMP`, the
        // switch that already means "write this dictation's places down for a
        // harness to read". The log is a plain file under `Library/Logs` and
        // it outlives the dictation, so a diagnostic that is on for everybody
        // spells names into it on runs where nothing was even offered.
        var census = "vocabulary: \(slots.count) slot(s) from \(parts.count) proposal(s)"
        if bySound > 0 { census += " (\(bySound) by sound)" }
        // Which of the two halves is on, not just that the gate is: a place
        // decided by the portrait alone reads nothing like one both tests saw.
        let reading = [
            (step.slotGate ?? true) ? "slot" : nil, (step.portrait ?? true) ? "portrait" : nil,
        ].compactMap { $0 }
        if config.vocabulary.gateSentence, !reading.isEmpty {
            census += ", sentence gate on (\(reading.joined(separator: " + ")))"
        }
        if !slots.isEmpty, ProcessInfo.processInfo.environment["PARROTFLOW_JUDGE_DUMP"] != nil {
            census += " — " + slots.map {
                "\"\(text[$0.range])\" (\($0.terms.joined(separator: "/")))"
            }.joined(separator: ", ")
        }
        Log.write(census)
        guard !slots.isEmpty else {
            return result(text, ["slots": .int(0)])
        }
        let changes = VocabularyJudge.changes(in: text, from: slots)
        guard !changes.isEmpty else {
            return result(text, ["slots": .int(slots.count)])
        }
        let taught = VocabularyJudge.teaching(in: text, changes: changes)

        // The free gates. A sound proposal gets both rules; a rule
        // substitution gets the two word lists only, and only in the direction
        // that keeps what the rule already wrote — see `settle`.
        //
        // `taught` wins over the gate, because a spelling lesson is settled by
        // a rule that is 4/4 where the models measured were 0/4.
        let gatedAt = Date()
        let settled: [Bool?]
        if step.gate ?? true {
            // `slot_gate: false` passes no gate at all, which is the path a
            // machine without the 269 MB model already takes: the word lists
            // settle what they settle and the slot is never asked. Read inside
            // the branch so `gate: false` does not load it either.
            let slot = (step.slotGate ?? true) ? await Vocabulary.shared.slotGate() : nil
            settled = VocabularyJudge.settle(
                changes, in: text, by: [.sound: .full, .rule: .lists], gate: slot)
        } else {
            settled = [Bool?](repeating: nil, count: changes.count)
        }
        var decided: [Bool?] = changes.indices.map { index in
            index < taught.count && taught[index] ? false : settled[index]
        }
        // The two tests that read the sentence, on whatever is still open.
        if config.vocabulary.gateSentence, #available(macOS 14, *) {
            decided = await SentenceGate.settle(
                changes, in: text, given: decided,
                floor: config.transcription.slotFloor(
                    for: Pipeline.language(of: text, config: config), on: step
                ),
                slot: step.slotGate ?? true, portrait: step.portrait ?? true
            )
        }
        gateSeconds = Date().timeIntervalSince(gatedAt)

        let gated = decided.enumerated().filter { $0.element != nil && !taught[$0.offset] }.count
        if gated > 0 {
            Log.write("vocabulary gate: \(gated) of \(changes.count) settled")
        }
        let open = decided.filter { $0 == nil }.count
        if open > 0 {
            Log.write("vocabulary: \(open) of \(changes.count) place(s) left open —"
                + " each keeps what is already there")
        }

        // A spelling lesson is reverted by the rule and nothing else looks at
        // it. Both models measured answered all four of the archive's cases
        // the wrong way, and the prompt paragraph that described the pattern
        // did not move them.
        let lessons = zip(changes, taught).filter { $0.1 }.map { "\($0.0.now) -> \($0.0.was)" }
        if !lessons.isEmpty {
            Log.write("vocabulary: spelling lesson, reverted — "
                + lessons.joined(separator: "; "))
        }

        // A refused span that glues to the term is the ordinary phrase, so its
        // capitals go with it — see `VocabularyJudge.lowercased`. A spelling
        // lesson is exempt: it writes back exactly what was typed.
        var writing = changes
        if step.lowercaseRefused ?? true {
            let terms = Array(config.vocabulary.terms.keys)
            for index in changes.indices where decided[index] == false {
                guard !(index < taught.count && taught[index]) else { continue }
                let change = changes[index]
                guard Vocabulary.glues(heard: change.was, term: change.now) else { continue }
                // The span as heard, because a rule has written its term over
                // it and the term is a different length.
                let heard = text.replacingCharacters(in: change.range, with: change.was)
                let at = text.distance(from: text.startIndex, to: change.range.lowerBound)
                guard let lower = VocabularyJudge.lowercased(
                    change.was, in: heard, at: at, terms: terms
                ) else { continue }
                writing[index] = VocabularyJudge.Change(
                    range: change.range, was: lower, now: change.now,
                    terms: change.terms, standing: change.standing
                )
                Log.write("vocabulary: \"\(change.was)\" refused as \(change.now)"
                    + " — written in lowercase")
            }
        }

        // Each place written the way it was settled, and a place nothing
        // settled left exactly as it already stands: a rule substitution keeps
        // the term it wrote, a sound proposal keeps the word that was heard.
        let chosen = VocabularyJudge.settling(decided, in: text, changes: writing)
        // What the stage undid, in the words it put back. Named `reverted`
        // rather than `kept_as_decoded`: every place on this list is a
        // substitution somebody has to answer for.
        let reverted = zip(writing, decided).filter { $0.1 == false }.map {
            "\($0.0.now) -> \($0.0.was)"
        }
        if chosen != text {
            Log.write("pipeline: vocabulary rewrote the transcript")
            Log.write("    before: \(text)")
            Log.write("    after:  \(chosen)")
        }
        return result(chosen, [
            "slots": .int(slots.count),
            "reverted": .string(reverted.joined(separator: "; ")),
            "judged": .string(chosen),
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
            // Exact and free, so there is nothing to guard — the log line is
            // the same one `replacements` writes, with the name that asked for
            // it. `protected` is the exception to "nothing to report": a table
            // has no code of its own to publish from, and what it wrote is
            // exactly what a later stage must not undo. `dotted` writes the dot
            // in `user.name` and `join` would otherwise read it as one the
            // decoder invented.
            let done = Replacements.exact(to: text, rules: transform.rules,
                                          expand: config.expanded)
            if done.text != text {
                Log.write("pipeline: transform \(name) rewrote the transcript")
                Log.write("    before: \(text)")
                Log.write("    after:  \(done.text)")
            }
            return StageResult(text: done.text, vars: [
                "count": .int(done.count),
                "protected": .string(done.protected),
            ])
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
        guard config.llmEnabled else {
            Log.write("pipeline: skipped prompt \(name) — `models:` defines no model")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }
        guard let transform = config.transform(named: name), let prompt = transform.asPrompt else {
            Log.write("pipeline: no prompt named \"\(name)\"; skipped")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }
        let model = config.model(for: transform)

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
                config: model
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
            return StageResult(text: result, vars: ["model": .string(model.model)])
        } catch {
            Log.write("pipeline: prompt \(name) failed (\(error.localizedDescription));"
                + " kept the transcript")
            return StageResult(text: text, vars: ["ok": .bool(false)])
        }
    }
}
