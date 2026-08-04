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

        enum CodingKeys: String, CodingKey {
            case languages, replacements, pipeline, transforms
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
    static func run(
        path: String, text: String?, quiet: Bool = false, app: String? = nil,
        allowPrompts: Bool = true
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
                stage: stage, transform: entry.transform, when: entry.when,
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

        let done = DispatchSemaphore(value: 0)
        if quiet {
            Task {
                print(await pipeline.run(
                    text, config: config, allowPrompts: allowPrompts, app: front
                ))
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
        for step in steps {
            if let reason = Pipeline.skipReason(
                for: step, text: current, config: config,
                allowPrompts: allowPrompts, app: front
            ) {
                print("  ⊘ \(step.stage.name)  — skipped, \(reason.described)")
                continue
            }
            var after = current
            let stepDone = DispatchSemaphore(value: 0)
            Task {
                after = await Pipeline(steps: [step]).run(
                    current, config: config, allowPrompts: allowPrompts, app: front
                )
                stepDone.signal()
            }
            stepDone.wait()
            if after == current {
                print("  · \(step.stage.name)  — ran, changed nothing")
            } else {
                print("  → \(step.stage.name)")
                print("      \(after)")
            }
            current = after
        }
        print("out:  \(current)")
        problems = []
        return 0
    }
}
