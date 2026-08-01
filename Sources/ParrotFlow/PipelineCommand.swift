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

        enum CodingKeys: String, CodingKey { case languages, replacements, pipeline }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let v = try c.decodeIfPresent([String].self, forKey: .languages) { languages = v }
            if let v = try c.decodeIfPresent([String: [String]].self, forKey: .replacements) {
                replacements = v
            }
            pipeline = try c.decodeIfPresent(
                [Config.Transcription.PipelineEntry].self, forKey: .pipeline
            ) ?? []
        }
    }

    static func run(path: String, text: String?, quiet: Bool = false) -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let fixture: Fixture
        do {
            fixture = try YAMLDecoder().decode(
                Fixture.self, from: String(contentsOf: url, encoding: .utf8)
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
            return Pipeline.Step(stage: stage, when: entry.when, unless: entry.unless)
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

        var problems = pipeline.validate()
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
                if let when = step.when { line += "  when \(when)" }
                if let unless = step.unless { line += "  unless \(unless)" }
                print(line)
            }
            return 0
        }

        if quiet {
            print(pipeline.run(text, config: config))
            return 0
        }

        // Stage by stage, because a pipeline that produced the wrong answer is
        // a question about which stage did it, and the finished string cannot
        // say. Re-run one stage at a time rather than instrumenting `run`: the
        // scored path stays the one the app uses, and this stays a viewer.
        print("in:   \(text)")
        var current = text
        for step in steps {
            guard step.shouldRun(on: current) else {
                let reason = step.unless.map { "unless \($0) matched" }
                    ?? step.when.map { "when \($0) did not match" } ?? "its condition"
                print("  ⊘ \(step.stage.name)  — skipped, \(reason)")
                continue
            }
            let after = Pipeline(steps: [step]).run(current, config: config)
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
