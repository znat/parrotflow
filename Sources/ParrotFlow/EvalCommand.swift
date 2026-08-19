import Foundation
import Yams

/// `--eval <transform>` — score a transform against its own case set.
///
/// Every rewrite in this repository ships with a case set and a bespoke runner
/// in `scripts/`. Users get neither, which makes "write a prompt and hope" the
/// only loop available to anyone who installed the app. This is the loop
/// docs/authoring.md prescribes, in the binary, against your own config.
///
///     ParrotFlow --eval slack_mentions                   transforms/…/cases.yaml
///     ParrotFlow --eval slack_mentions --cases heldout.yaml
///     ParrotFlow --eval slack_mentions --verbose --probe ambiguity_common
///     ParrotFlow --eval path/to/cases.yaml               one-off, outside a folder
///
/// The transform is resolved from your real config and **that** is what runs —
/// not a reimplementation of it. `scripts/validate-slack-mentions.py` imports
/// the shipped script for the same reason: two copies of an algorithm drift,
/// and only one of them ships. The note in docs/authoring.md about a runner
/// drifting from the app is worth 31 points of measured error.
enum EvalCommand {

    /// The bucket for cases that named no `probe:`.
    private static let unlabelled = "(no probe)"

    static func run(
        target: String, cases override: String?, probe: String?, verbose: Bool
    ) -> Int32 {
        var config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            print("✗ \(ConfigStore.fileURL.path): \(CheckConfigCommand.describe(error))")
            return 1
        }

        guard let found = locate(target, cases: override, config: config) else { return 1 }
        let (file, set, transform) = found

        // A set that carries its own `lists:` states what it assumes, the way
        // it already can with `transforms:`. Without this a `{{name}}` in a
        // transform the set carries would resolve against whichever machine is
        // scoring it. All of them, not merged: a set says what it assumes, and
        // `lists: {}` therefore means none rather than "this machine's".
        if let stated = set.lists { config.lists = stated }

        // The rules that are about to run, checked before anything is scored.
        // A `{{name}}` that resolves to nothing makes the rule match nothing,
        // and a set would score that as "the transform did not fire" — a wrong
        // number rather than an error, which is the failure a case set exists
        // to prevent. Only this transform's rules: another entry's mistake is
        // `--check-config`'s to report, not this run's to fail on.
        var underTest = Config()
        underTest.lists = config.lists
        underTest.transforms = [transform]
        let ruleProblems = underTest.replacementProblems()
        guard ruleProblems.isEmpty else {
            print("✗ \(short(file.path)) scores \"\(transform.name)\":")
            for problem in ruleProblems { print("    \(problem)") }
            return 1
        }

        // What `--probe` selected, decided once and handed to everything that
        // reads a case — validation, the gold check, the scoring. Deciding it
        // twice is how the gold check came to send every case to the resolver
        // while the scoring loop ran a subset: `resolve:` is a `command:` like
        // any other, and an input somebody filtered out must not reach
        // someone's program by a side door.
        let selected = probe.map { wanted in set.cases.filter { $0.probe == wanted } } ?? set.cases
        guard !selected.isEmpty else {
            let known = Set(set.cases.map(\.probe)).filter { !$0.isEmpty }.sorted()
            print("✗ no case has probe \"\(probe ?? "")\""
                + (known.isEmpty
                    ? " — no case in this set names one"
                    : " — have: \(known.joined(separator: ", "))"))
            return 1
        }

        let problems = set.problems(for: selected)
        guard problems.isEmpty else {
            print("✗ \(short(file.path)):")
            for problem in problems { print("    \(problem)") }
            return 1
        }

        print("eval: \(transform.name)")
        print("  cases    \(short(file.path))  (\(set.cases.count))"
            + (probe.map { "  — only probe \($0)" } ?? ""))
        print("  body     \(body(of: transform))")
        // A subset run is not a clean bill of health for the file. Said only
        // when there is something to say, so it stays a signal.
        let elsewhere = probe.map { wanted in
            set.problems(for: set.cases.filter { $0.probe != wanted })
        } ?? []
        if !elsewhere.isEmpty {
            print("  · \(elsewhere.count) problem(s) in cases outside this probe,"
                + " not checked here — run without --probe to see them")
        }

        // The gold, against itself, before anything is scored. A typo in an
        // intermediate gold otherwise scores every candidate against a typo,
        // silently, forever — so this is a refusal and not a warning.
        if let intermediate = set.intermediate {
            let wrong = badGold(selected, intermediate, transform: transform)
            guard wrong.isEmpty else {
                print("")
                print("  ✗ the gold does not agree with itself."
                    + " Resolving `\(intermediate.field)` must produce `expect`.")
                for line in wrong.prefix(10) { print("      \(line)") }
                if wrong.count > 10 { print("      … and \(wrong.count - 10) more") }
                print("")
                print("  Nothing was scored. A set that disagrees with itself scores"
                    + " every candidate against its own typo.")
                return 1
            }
            print("  gold     \(selected.count) cases resolve to their `expect`")
        }

        let scored = score(set, selected: selected, transform: transform, config: config)
        report(scored, set: set, probe: probe, verbose: verbose)
        // 0 means "this was scored", not "this was perfect. A set worth having
        // keeps its residue in, failing — tests/…/dotted/cases.txt scores 54/54
        // and carries two more it cannot do — so a number below 100% is an
        // ordinary result and not an error to report to a shell. What exits 1
        // is a set that could not be scored at all.
        return 0
    }

    // MARK: - Finding what to score

    /// The case file, the set in it, and the transform it belongs to.
    ///
    /// Two ways in. A **name** is looked up in your config and its set is
    /// `transforms/<name>/cases.yaml` by convention. A **path** to a file is
    /// the one-off: the transform is whatever the file's `transform:` says, or
    /// failing that the folder it sits in, which is the same answer for a set
    /// that lives where it belongs.
    private static func locate(
        _ target: String, cases override: String?, config: Config
    ) -> (URL, EvalCases, Config.Transform)? {
        let path = (target as NSString).expandingTildeInPath
        let asFile = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        let namesAFile = FileManager.default.fileExists(
            atPath: asFile.path, isDirectory: &isDirectory
        ) && !isDirectory.boolValue

        let file: URL
        var name: String
        if namesAFile {
            file = asFile
            name = asFile.deletingLastPathComponent().lastPathComponent
        } else {
            name = target
            guard let transform = config.transform(named: target) else {
                print("✗ no transform named \"\(target)\""
                    + (config.transforms.isEmpty
                        ? " — `transforms:` is empty"
                        : " — have: \(config.transforms.map(\.name).joined(separator: ", "))"))
                return nil
            }
            // `--cases` wins over the transform's own `tests:`, which wins over
            // the `cases.yaml` every folder has by convention.
            let wanted = override ?? transform.tests ?? "cases.yaml"
            guard let found = transform.folder?.resolve(wanted) else {
                let folder = transform.folder?.url?.path ?? ConfigStore.directory.path
                print("✗ no \(wanted) for \"\(transform.name)\""
                    + " — expected it in \(short(folder))")
                print("    a transform's case set lives in its own folder;"
                    + " see docs/authoring.md")
                return nil
            }
            file = found.url
        }

        let set: EvalCases
        do {
            set = try YAMLDecoder().decode(
                EvalCases.self, from: String(contentsOf: file, encoding: .utf8),
                userInfo: [.configDirectory: file.deletingLastPathComponent()]
            )
        } catch {
            print("✗ \(short(file.path)): \(CheckConfigCommand.describe(error))")
            return nil
        }
        if let declared = set.transform, !declared.isEmpty { name = declared }

        // The set's own `transforms:` wins, so a case file can carry the
        // transform it assumes and score the same on any machine.
        let transform = set.transforms.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        } ?? config.transform(named: name)
        guard let transform else {
            print("✗ \(short(file.path)) scores \"\(name)\", which is not in your config"
                + " and not in the file")
            return nil
        }
        // The same refusal `Pipeline.validate` makes, made here because
        // `--eval` builds its one-step pipeline rather than loading one. A
        // transform called `lists` or `asr` would file its variables where the
        // runner has already put something, and score against its own damage.
        return (file, set, transform)
    }

    // MARK: - Running

    /// One case through the real transform.
    ///
    /// A one-step pipeline rather than a switch over the body: that is the code
    /// the app runs, including the part where every way of failing returns the
    /// transcript exactly as it arrived.
    private static func through(
        _ transform: Config.Transform, _ text: String, config: Config, instruction: String,
        language: String? = nil
    ) -> (output: String, seconds: TimeInterval) {
        // A prompt reached by voice is given what the speaker actually said,
        // and the same prompt in a pipeline is given nothing — "format those
        // dates ISO" and a stage that runs on every transcript are one rule and
        // two instructions. A set has to be able to say which of the two it is
        // scoring, or the number describes a use nobody has. Both go through
        // `PromptRunner`, which is the function both paths in the app call.
        if !instruction.isEmpty, let prompt = transform.asPrompt {
            return asked(prompt, text, instruction: instruction, config: config)
        }

        var config = config
        // The transform that was resolved is the one that runs, whichever of
        // the two it came from.
        //
        // Putting it first rather than only when the name is free: `locate`
        // already decided, preferring the set's own `transforms:` so a case
        // file can state what it assumes. Appending only when the config had
        // no entry of that name handed the decision back to the config — and
        // silently, on exactly the machines where the two disagree, which is
        // the case the set carried its own transform to survive.
        config.transforms.removeAll { $0.name.caseInsensitiveCompare(transform.name) == .orderedSame }
        config.transforms.insert(transform, at: 0)
        let pipeline = Pipeline(steps: [Pipeline.Step(stage: .transform, transform: transform.name)])
        var output = text
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        // Seeded, so `Pipeline` keeps it instead of detecting one. Absent, the
        // detector runs exactly as it does for a real dictation.
        var seed = Scope()
        if let language { seed.set("language", .string(language)) }
        Task {
            output = await pipeline.run(text, config: config, seed: seed)
            done.signal()
        }
        done.wait()
        return (output, Date().timeIntervalSince(started))
    }

    /// One case through a prompt, with the instruction a speaker would give.
    ///
    /// Failing open the way the pipeline does: an unreachable model returns the
    /// text unchanged rather than an error, so a run without Ollama scores 0 on
    /// the change half and 100% on the keep half — which is the truth about
    /// what the app would do, and is legible as such.
    private static func asked(
        _ prompt: Config.Prompt, _ text: String, instruction: String, config: Config
    ) -> (output: String, seconds: TimeInterval) {
        let llm = config.transform(named: prompt.name)
            .map { config.model(for: $0) } ?? config.model()
        var output = text
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            output = (try? await PromptRunner.run(
                prompt: prompt, instruction: instruction, text: text, config: llm
            )) ?? text
            done.signal()
        }
        done.wait()
        return (output.isEmpty ? text : output, Date().timeIntervalSince(started))
    }

    /// A helper command out of the case file — the control, or an
    /// intermediate's `produce`/`resolve` — run in the transform's own folder.
    private static func piped(
        _ command: String, _ text: String, in transform: Config.Transform
    ) -> String {
        CommandRunner.run(
            command, on: text, in: transform.folder, seconds: transform.timeout
        ) ?? text
    }

    // MARK: - Scoring

    struct Tally {
        var passed = 0
        var total = 0

        mutating func add(_ correct: Bool) {
            total += 1
            if correct { passed += 1 }
        }

        var percent: Int { total == 0 ? 0 : Int((Double(passed) / Double(total) * 100).rounded()) }
        /// No percentage of nothing. "0/0 = 0%" reads as a half that failed
        /// rather than as a half this set does not have.
        var described: String { total == 0 ? "none in this set" : "\(passed)/\(total) = \(percent)%" }
    }

    struct Failure {
        var name: String
        var probe: String
        var input: String
        var got: String
        var want: String
        var half: String
    }

    struct Scored {
        var overall = Tally()
        /// Cases that ask for a change.
        var change = Tally()
        /// Cases that must come back byte for byte — see `report`.
        var keep = Tally()
        var probes: [String: Tally] = [:]
        var latencies: [TimeInterval] = []
        var failures: [Failure] = []
        /// The same three, for the no-model control, when the set declares one.
        var control: (overall: Tally, change: Tally, keep: Tally)?
        /// The first stage alone, when the set declares an intermediate gold.
        var intermediate: Tally?
    }

    private static func score(
        _ set: EvalCases, selected: [EvalCases.Case],
        transform: Config.Transform, config: Config
    ) -> Scored {
        var scored = Scored()
        let instruction = set.instruction ?? ""
        var control = (overall: Tally(), change: Tally(), keep: Tally())
        var intermediate = Tally()

        // Warm first, and throw the number away. A cold start is 7–10s of
        // reading weights off a disk and has nothing to say about the thing
        // being measured; timings that include it send you optimising it. It
        // is a case that is about to be scored anyway, so this costs one extra
        // run of one input rather than one of an input nobody asked for.
        if let first = selected.first {
            _ = through(transform, first.input, config: config, instruction: instruction,
                        language: first.language)
        }

        for one in selected {
            let (got, seconds) = through(transform, one.input, config: config,
                                         instruction: instruction, language: one.language)
            let correct = got == one.expect
            scored.overall.add(correct)
            scored.latencies.append(seconds)
            if one.mustNotChange { scored.keep.add(correct) } else { scored.change.add(correct) }
            // Everything lands in a bucket, including the cases that named no
            // probe. A grid that silently covers 61 of 75 reads as a complete
            // breakdown and is not one.
            scored.probes[one.probe.isEmpty ? unlabelled : one.probe, default: Tally()]
                .add(correct)
            if !correct {
                scored.failures.append(Failure(
                    name: one.name, probe: one.probe, input: one.input,
                    got: got, want: one.expect,
                    half: one.mustNotChange ? "keep" : "change"
                ))
            }

            if let command = set.control, !command.isEmpty {
                let answer = piped(command, one.input, in: transform)
                let right = answer == one.expect
                control.overall.add(right)
                if one.mustNotChange { control.keep.add(right) } else { control.change.add(right) }
            }

            if let declared = set.intermediate, let produce = declared.produce,
               let gold = one.fields[declared.field] {
                intermediate.add(piped(produce, one.input, in: transform) == gold)
            }
        }

        if set.control?.isEmpty == false { scored.control = control }
        if intermediate.total > 0 { scored.intermediate = intermediate }
        return scored
    }

    /// The cases whose gold does not resolve to their own `expect`.
    private static func badGold(
        _ cases: [EvalCases.Case], _ intermediate: EvalCases.Intermediate,
        transform: Config.Transform
    ) -> [String] {
        cases.compactMap { one in
            guard let gold = one.fields[intermediate.field] else { return nil }
            let resolved = piped(intermediate.resolve, gold, in: transform)
            guard resolved != one.expect else { return nil }
            return "\(one.name)\n          \(intermediate.field) resolves to  \(resolved)"
                + "\n          expect is             \(one.expect)"
        }
    }

    // MARK: - Reporting

    private static func report(
        _ scored: Scored, set: EvalCases, probe: String?, verbose: Bool
    ) {
        print("")
        // The two halves, separately and always.
        //
        // A rewrite that scores well on `change` and badly on `keep` is not a
        // rewrite that is 80% there — it is one that makes you proof-read every
        // dictation, which is the whole thing this app exists to avoid. An
        // average across the two can hide that completely, so there is no
        // arrangement of this output in which it is only an average.
        print("  change   \(scored.change.described)")
        print("  keep     \(scored.keep.described)"
            + "   <- must come back byte for byte")
        print("  overall  \(scored.overall.described)")

        if let control = scored.control {
            print("")
            print("  the same set, without a model — is the model earning its place?")
            print("    change   \(control.change.described)")
            print("    keep     \(control.keep.described)")
            print("    overall  \(control.overall.described)")
        }

        if let intermediate = scored.intermediate {
            print("")
            print("  the first stage alone   \(intermediate.described)")
            print("    above the overall, the code is repairing the model;"
                + " below it, the code is the fault")
        }

        // By probe, never only an aggregate: one broken category hides behind
        // eleven healthy ones for exactly as long as nobody breaks it out.
        if scored.probes.count > 1 {
            print("")
            print("  by probe")
            let width = scored.probes.keys.map(\.count).max() ?? 0
            for name in scored.probes.keys.sorted() {
                guard let tally = scored.probes[name] else { continue }
                let padded = name.padding(toLength: width, withPad: " ", startingAt: 0)
                print("    \(padded)  \(tally.passed)/\(tally.total)"
                    + (tally.passed == tally.total ? "" : "  ←"))
            }
        }
        if scored.probes[unlabelled] != nil, probe == nil {
            print("")
            print("  · \(scored.probes[unlabelled]?.total ?? 0) cases name no `probe:`."
                + " Grouped ones say \"all the two-word cases broke\";"
                + " ungrouped ones say only that four points went missing.")
        }

        if !scored.latencies.isEmpty {
            let sorted = scored.latencies.sorted()
            let median = sorted[sorted.count / 2]
            print("")
            print(String(
                format: "  latency  %.2fs median, %.2fs worst, warm", median, sorted[sorted.count - 1]
            ))
        }

        guard !scored.failures.isEmpty else { return }
        print("")
        let shown = verbose ? scored.failures : Array(scored.failures.prefix(5))
        for failure in shown {
            let bucket = failure.probe.isEmpty
                ? failure.half : "\(failure.half), \(failure.probe)"
            print("  ✗ \(failure.name)  [\(bucket)]")
            if failure.name != failure.input { print("      in    \(failure.input)") }
            print("      got   \(failure.got)")
            print("      want  \(failure.want)")
        }
        if !verbose, scored.failures.count > shown.count {
            print("  … and \(scored.failures.count - shown.count) more; --verbose for all")
        }
    }

    // MARK: -

    private static func body(of transform: Config.Transform) -> String {
        let kind: String
        switch transform.body {
        case .prompt: kind = "prompt "
        case .replace: kind = "replace"
        case .command: kind = "command"
        }
        if let found = transform.resolvedSource { return "\(kind)  \(short(found.path))" }
        if case .command(let command) = transform.body { return "\(kind)  \(command) — on PATH" }
        return "\(kind)  inline"
    }

    private static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
