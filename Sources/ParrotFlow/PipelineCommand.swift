import Foundation
import Yams

/// `--pipeline <file> "<text>"` — runs a pipeline written in a file, not the
/// one in your config.
///
/// The point is that a case can say what it exercises. Scoring a pipeline
/// against the config on the machine that happens to be running is how
/// tests/routing-cases.yaml ended up coupled to whichever prompts a person had
/// configured, and the expectations then only meant anything on one laptop.
///
/// So a fixture carries everything the pipeline needs — the stages, the
/// languages, and its own replacement table — and running it touches no config
/// at all:
///
///     languages: [fr, en]
///     replacements:
///       Supabase: [super base]
///     pipeline:
///       - replacements
///       - stage: numbers
///         unless: /```/
///
/// Without `--quiet` it prints each stage's before and after, and names the
/// ones it skipped along with the condition that skipped them — which is the
/// question you actually have when a pipeline does not do what you expected.
enum PipelineCommand {

    /// A fixture is a config with everything irrelevant left out.
    private struct Fixture: Decodable {
        var languages: [String] = ["en"]
        var replacements: [String: [String]] = [:]
        var pipeline: [Config.Transcription.PipelineEntry] = []
        /// Its own `transforms:`, decoded by `Config` rather than re-read here,
        /// so a fixture cannot disagree with a config about what a transform is.
        var transforms: [Config.Transform] = []
        /// Its own vocabulary. Only the `vocabulary` stage reads it, and only
        /// for the `heard:` renderings — a fixture cannot make a sound, so
        /// there is nothing here for the acoustic half.
        var vocabulary: Config.Vocabulary?
        /// Its own `lists:`. A pattern that says `{{determiners}}` compiles to
        /// nothing without them, and a guard that silently stops guarding is
        /// the failure a fixture exists to catch.
        var lists: [String: [String]] = [:]

        enum CodingKeys: String, CodingKey {
            case languages, replacements, pipeline, transforms, vocabulary, lists
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let v = try c.decodeIfPresent([String].self, forKey: .languages) { languages = v }
            if let v = try c.decodeIfPresent([String: [String]].self, forKey: .replacements) {
                replacements = v
            }
            pipeline = try c.decodeIfPresent(
                [Config.Transcription.PipelineEntry].self, forKey: .pipeline
            ) ?? []
            if c.contains(.transforms) {
                // Round-tripped through Config's own decoder: the fixture's
                // section is handed back to the type that reads the real one.
                let nested = try c.superDecoder(forKey: .transforms)
                transforms = try Config.transforms(from: nested)
            }
            if let v = try c.decodeIfPresent([String: [String]].self, forKey: .lists) {
                lists = v
            }
            vocabulary = try c.decodeIfPresent(Config.Vocabulary.self, forKey: .vocabulary)
        }
    }

    /// `--app "Ghostty com.mitchellh.ghostty"` — who to pretend is in front.
    ///
    /// Without it an `app:` condition is only reachable by speaking into the
    /// right window, which is not a thing a validation set can do. The string
    /// is matched exactly as the real one is: name and bundle identifier
    /// joined, so a fixture can name either or both.
    ///
    /// Empty is "nothing in front", not "no flag given" — the two mean the same
    /// thing here, and saying so lets a caller pass the flag unconditionally.
    /// scripts/check-pipeline.sh does exactly that, because the alternative in
    /// bash 3.2 is an empty array under `set -u`, which is an error.
    ///
    /// `--no-prompts` mirrors what `--replace` does, the only other caller that
    /// turns them off. Without it, "a table still runs when prompts are off" is
    /// a claim no fixture can make — and it was wrong until something ran it.
    /// `--vars` prints the scope when the pipeline is done: every variable, by
    /// full path, sorted. It is how a case set asserts on something other than
    /// the finished string — a stage that publishes `count: 3` and changes no
    /// text is invisible to `expect:` and is exactly the kind of stage worth
    /// testing. Printed before the output line so that `--quiet | tail -1` still
    /// means what it has always meant.
    static func run(
        path: String, text: String?, quiet: Bool = false, app: String? = nil,
        allowPrompts: Bool = true, showVars: Bool = false
    ) -> Int32 {
        let named = (app ?? "").trimmingCharacters(in: .whitespaces)
        let front = named.isEmpty ? nil : Pipeline.App(name: named, bundleID: "")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let fixture: Fixture
        do {
            fixture = try YAMLDecoder().decode(
                Fixture.self, from: String(contentsOf: url, encoding: .utf8),
                userInfo: [.configDirectory: url.deletingLastPathComponent()]
            )
        } catch {
            print("✗ \(path): \(CheckConfigCommand.describe(error))")
            return 1
        }

        var unknown: [String] = []
        let steps = fixture.pipeline.compactMap { entry -> Pipeline.Step? in
            guard let stage = Pipeline.stage(named: entry.name) else {
                unknown.append(entry.name)
                return nil
            }
            return Pipeline.Step(
                stage: stage, transform: entry.transform, prompt: entry.prompt,
                caps: entry.caps, fuzzy: entry.fuzzy, when: entry.when,
                unless: entry.unless, app: entry.app
            )
        }
        for name in unknown {
            print("✗ \"\(name)\" is not a stage — have: \(Pipeline.stageNames.joined(separator: ", "))")
        }
        guard unknown.isEmpty else { return 1 }

        let pipeline = Pipeline(steps: steps)
        var config = Config()
        config.transcription.languages = fixture.languages
        config.transcription.replacements = fixture.replacements
        config.transcription.pipelines = ["default": pipeline]
        config.transforms = fixture.transforms
        config.lists = fixture.lists
        if let vocabulary = fixture.vocabulary { config.vocabulary = vocabulary }

        // The fixture's own table is checked too, not just its stage list — a
        // template naming a group the pattern never captures is refused here
        // for the same reason `--check-config` refuses it, and being reachable
        // from a fixture is what lets a validation set cover it at all.
        var problems = pipeline.validate() + config.replacementProblems()
        for problem in problems { print("✗ \(problem)") }
        guard problems.isEmpty else { return 1 }

        // No text: report the pipeline itself. "Which stages, in what order,
        // gated by what" is a question worth answering without inventing a
        // sentence to ask it with.
        guard let text else {
            print("pipeline:   \(path)")
            print("languages:  \(fixture.languages.joined(separator: ", "))")
            for step in steps {
                var line = "  \(step.stage.name)"
                if let transform = step.transform { line += " \(transform)" }
                if let when = step.when { line += "  when \(when)" }
                if let unless = step.unless { line += "  unless \(unless)" }
                if let app = step.app { line += "  app \(app)" }
                print(line)
            }
            return 0
        }

        // The same seed a live dictation gets from `Replacements.apply`. Without
        // it a condition reading `language` would work in the app and fail here,
        // and a fixture that cannot reproduce the app is not a fixture.
        // `Pipeline.forText` is asked rather than `DictationLanguage` directly,
        // so the answer is the one that would have selected the stages.
        var seed = Scope()
        seed.set("language", .string(Pipeline.forText(text, config: config).1))

        let done = DispatchSemaphore(value: 0)
        if quiet {
            Task {
                let result = await pipeline.runCollectingScope(
                    text, config: config, allowPrompts: allowPrompts, app: front, seed: seed
                )
                if showVars { printVars(result.scope) }
                print(result.text)
                done.signal()
            }
            done.wait()
            return 0
        }

        // Stage by stage, because a pipeline that produced the wrong answer is
        // a question about which stage did it, and the finished string cannot
        // say. Re-run one stage at a time rather than instrumenting `run`: the
        // scored path stays the one the app uses, and this stays a viewer.
        // The same things `--check-config` says about a config: which entries
        // run a program, and which of their files are still at the old
        // location. A fixture can carry a `command:` transform, so a fixture
        // can execute code, and the rule that this app says out loud what
        // executes does not stop at the file called config.yaml.
        for notice in config.notices() { print("  · \(notice)") }
        print("in:   \(text)")
        if let front { print("app:  \(front.described)") }
        var current = text
        // Threaded, not restarted. Each step is still run on its own so that its
        // own before and after can be printed, but the scope it inherits is the
        // one the steps above it built — otherwise a condition reading
        // `code_identifiers.count` would find nothing here while working
        // perfectly in the pipeline this is supposed to be a view of, and a
        // diagnostic that disagrees with the thing it diagnoses is worse than
        // none.
        var scope = seed
        for step in steps {
            let namespace = Pipeline.namespace(of: step)
            var after = current
            let stepDone = DispatchSemaphore(value: 0)
            Task {
                let result = await Pipeline(steps: [step]).runCollectingScope(
                    current, config: config, allowPrompts: allowPrompts, app: front,
                    seed: scope
                )
                after = result.text
                scope = result.scope
                stepDone.signal()
            }
            stepDone.wait()

            // Asked of the same scope the step was given, so the reason printed
            // is the reason that fired. `skipReason` is called a second time
            // rather than reported back out of `run` because the run above has
            // already decided — this only needs the words.
            if let reason = Pipeline.skipReason(
                for: step, text: current, config: config,
                allowPrompts: allowPrompts, app: front, scope: scope
            ) {
                print("  ⊘ \(step.stage.name)  — skipped, \(reason.described)")
                continue
            }
            if after == current {
                print("  · \(step.stage.name)  — ran, changed nothing")
            } else {
                print("  → \(step.stage.name)")
                print("      \(after)")
            }
            let published = scope.namespace(namespace)
                .filter { $0.key != "ran" && $0.key != "ok" && $0.key != "ms" }
            if !published.isEmpty {
                print("      " + published.keys.sorted()
                    .map { "\(namespace).\($0) = \(published[$0]!.described)" }
                    .joined(separator: "  "))
            }
            current = after
        }
        if showVars { printVars(scope) }
        print("out:  \(current)")
        problems = []
        return 0
    }

    /// Every variable, by full path, one per line.
    ///
    /// `text` is left out: it is the sentence, it is printed twice already, and
    /// a multi-line email in the middle of a variable listing makes the listing
    /// unreadable for the one value nobody needed it for.
    private static func printVars(_ scope: Scope) {
        for path in scope.paths where path != "text" {
            guard let value = scope[path] else { continue }
            print("var   \(path) = \(value.described)")
        }
    }
}
