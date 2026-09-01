import AppKit

// Terminal entry points, mostly for diagnosing "why isn't it recording":
//
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --record 3
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --transcribe clip.wav
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --warm-models
//
let arguments = CommandLine.arguments

// Log writes are asynchronous, which is right for a menu bar app and wrong for
// a command that exits the moment it has printed: the process is gone before
// the queue drains and the lines are silently lost. Two commands remembered to
// flush and the rest did not, so `--replace` was dropping the very lines that
// explain what the pipeline did — a stage saying it skipped, and why. Doing it
// here covers every path, including the ones added later.
atexit { Log.flush(); Trace.flush() }

// First, and above the config: this is the handshake that says which code you
// are running, and it must answer even when the config is broken or missing.
if arguments.contains("--version") {
    print(AppVariant.buildStamp)
    exit(0)
}

// The first line of every run, app or command, and above the config for the
// same reason: loading the config already logs — a transform it refused, a
// vocabulary.yaml it wrote — and those lines need the stamp above them to say
// which code produced them.
Log.write("build: \(AppVariant.buildStamp)")

// Before anything reads the config, because reading it creates it: `load`
// calls `createIfMissing`, so a line below that merely wants the output
// directory would seed the files this command exists to report on, and every
// run would say they were already there.
if arguments.contains("--seed-config") {
    exit(SeedConfigCommand.run())
}

// Where `trace.jsonl` goes, for every command below that writes one. The app
// sets this again from `applyConfig`, which is the copy that follows a live
// edit of `output_dir`; this is only so a terminal command has somewhere to
// write before any of that has run. Silent when the config will not load —
// a trace is a debug artefact and must not be the reason a command fails.
Trace.directory = (try? ConfigStore.load())?.resolvedOutputDir

/// `--lang fr` or `--lang en,fr`. One entry pins a grammar; several stand in
/// for the configured list, so a case file can state the environment it assumes
/// instead of inheriting this machine's.
func languageList(_ arguments: [String]) -> [String]? {
    guard let index = arguments.firstIndex(of: "--lang"),
          arguments.indices.contains(index + 1) else { return nil }
    let listed = arguments[index + 1]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return listed.isEmpty ? nil : listed
}

if arguments.contains("--check-config") {
    exit(CheckConfigCommand.run())
}

// Everything the bug form asks for, in one paste. `--url` prints the prefilled
// issue URL instead, which is what the menu item opens.
//
// Always 0, config or no config: a report about a broken install is exactly the
// one that has to come out.
if arguments.contains("--bug-report") {
    if arguments.contains("--url") {
        print(BugReport.issueURL()?.absoluteString ?? "\(AppVariant.repository)/issues/new")
    } else {
        print(BugReport.text(fromTerminal: true))
    }
    exit(0)
}

/// `--app <name>`, for the commands that run a pipeline. Shared so the flag
/// means the same thing to each of them.
let appArgument: String? = arguments.firstIndex(of: "--app").flatMap { index in
    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
}

if let index = arguments.firstIndex(of: "--record") {
    let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) : nil
    exit(RecordTestCommand.run(seconds: seconds ?? 3))
}

if arguments.contains("--audio-recovery") {
    let casesPath = arguments.firstIndex(of: "--cases").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    }
    exit(AudioRecoveryCommand.run(casesPath: casesPath))
}

if let index = arguments.firstIndex(of: "--set-key") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --set-key <model> [--forget]")
        exit(2)
    }
    exit(SetKeyCommand.run(
        model: arguments[index + 1],
        forget: arguments.contains("--forget")
    ))
}

if let index = arguments.firstIndex(of: "--transcribe") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --transcribe <file.wav> [--no-vocab]")
        exit(2)
    }
    exit(TranscribeCommand.run(
        path: arguments[index + 1],
        withVocabulary: !arguments.contains("--no-vocab")
    ))
}

if arguments.contains("--warm-models") {
    exit(WarmModelsCommand.run())
}

if arguments.contains("--sentence-model") {
    guard #available(macOS 14, *) else {
        print("✗ the sentence model needs macOS 14 or later")
        exit(1)
    }
    exit(SentenceModelCommand.run())
}

if let at = arguments.firstIndex(of: "--sentence-probe") {
    guard #available(macOS 14, *) else {
        print("✗ the sentence probe needs macOS 14 or later")
        exit(1)
    }
    if let encode = arguments.firstIndex(of: "--encode"), arguments.indices.contains(encode + 1) {
        exit(SentenceProbeCommand.encode(arguments[encode + 1]))
    }
    guard arguments.indices.contains(at + 2) else {
        print("usage: ParrotFlow --sentence-probe \"<left half>\" \"<right half>\"")
        print("       ParrotFlow --sentence-probe --encode \"<text>\"")
        exit(2)
    }
    exit(SentenceProbeCommand.run(left: arguments[at + 1], right: arguments[at + 2]))
}

if let at = arguments.firstIndex(of: "--sentence-join") {
    guard #available(macOS 14, *) else {
        print("✗ the sentence probe needs macOS 14 or later")
        exit(1)
    }
    let caseOnly = arguments.contains("--case")
    let text = arguments[(at + 1)...].first { !$0.hasPrefix("--") }
    guard let text else {
        print("usage: ParrotFlow --sentence-join [--case] \"<text>\"")
        exit(2)
    }
    exit(SentenceJoinCommand.run(text, caseOnly: caseOnly))
}

if let index = arguments.firstIndex(of: "--replace") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --replace \"<text>\" [--app <name>]")
        exit(2)
    }
    exit(ReplaceCommand.run(text: arguments[index + 1], app: appArgument))
}

if let index = arguments.firstIndex(of: "--numbers") {
    let text = arguments.indices.contains(index + 1) && !arguments[index + 1].hasPrefix("--")
        ? arguments[index + 1] : nil
    exit(NumbersCommand.run(
        text: text, quiet: arguments.contains("--quiet"), languages: languageList(arguments)
    ))
}

if let index = arguments.firstIndex(of: "--normalize") {
    let text = arguments.indices.contains(index + 1) && !arguments[index + 1].hasPrefix("--")
        ? arguments[index + 1] : nil
    exit(NormalizeCommand.run(text: text))
}

if let index = arguments.firstIndex(of: "--inflected") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --inflected <term> <heard>")
        exit(2)
    }
    exit(InflectedCommand.run(term: arguments[index + 1], heard: arguments[index + 2]))
}

if let index = arguments.firstIndex(of: "--word-gate") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --word-gate <word> [term]")
        exit(2)
    }
    // The term is optional, and the next argument is only the term when it is
    // not another flag.
    let term = arguments.indices.contains(index + 2)
        && !arguments[index + 2].hasPrefix("--") ? arguments[index + 2] : nil
    let sentence = arguments.firstIndex(of: "--in").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    }
    exit(WordGateCommand.run(word: arguments[index + 1], term: term, sentence: sentence))
}

if let index = arguments.firstIndex(of: "--suggest") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --suggest \"<sentence>\" [--lang fr]")
        exit(2)
    }
    exit(SuggestCommand.run(text: arguments[index + 1],
                            language: languageList(arguments)?.first))
}

if let index = arguments.firstIndex(of: "--verdicts") {
    guard arguments.indices.contains(index + 2), let count = Int(arguments[index + 1]) else {
        print("usage: ParrotFlow --verdicts <count> <reply>")
        exit(2)
    }
    exit(VerdictsCommand.run(count: count, reply: arguments[index + 2]))
}

if let index = arguments.firstIndex(of: "--teaching") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --teaching \"<sentence>\" <word>")
        exit(2)
    }
    exit(TeachingCommand.run(text: arguments[index + 1], word: arguments[index + 2]))
}

if let index = arguments.firstIndex(of: "--command") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --command \"hey parrot, Tasmin spells T A S M E E N\""
            + " [--phrases \"a,b\"]")
        exit(2)
    }
    let context = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
        ? arguments[index + 2] : nil
    // An empty list is a case of its own — spoken commands turned off — so it
    // has to survive as [] rather than collapse back to the configured list.
    let phrases = arguments.firstIndex(of: "--phrases").flatMap { at -> [String]? in
        guard arguments.indices.contains(at + 1) else { return nil }
        return arguments[at + 1]
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    exit(CommandTestCommand.run(
        text: arguments[index + 1], lastTranscript: context, phrases: phrases
    ))
}

if let index = arguments.firstIndex(of: "--route") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --route \"hey parrot, make that a bullet list\" [--quiet] [--keyed]")
        exit(2)
    }
    exit(RouteTestCommand.run(
        text: arguments[index + 1], quiet: arguments.contains("--quiet"),
        keyed: arguments.contains("--keyed")
    ))
}

if let index = arguments.firstIndex(of: "--prompt") {
    guard arguments.indices.contains(index + 3) else {
        print("usage: ParrotFlow --prompt <name> \"<instruction>\" \"<text>\" [--quiet]")
        exit(2)
    }
    exit(PromptRunCommand.run(
        name: arguments[index + 1],
        instruction: arguments[index + 2],
        text: arguments[index + 3],
        quiet: arguments.contains("--quiet")
    ))
}

if let index = arguments.firstIndex(of: "--eval") {
    guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
        print("usage: ParrotFlow --eval <transform|cases.yaml>"
            + " [--cases <file>] [--probe <name>] [--verbose]")
        exit(2)
    }
    func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { at in
            arguments.indices.contains(at + 1) && !arguments[at + 1].hasPrefix("--")
                ? arguments[at + 1] : nil
        }
    }
    exit(EvalCommand.run(
        target: arguments[index + 1],
        cases: value("--cases"),
        probe: value("--probe"),
        verbose: arguments.contains("--verbose")
    ))
}

if let index = arguments.firstIndex(of: "--pipeline") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --pipeline <file.yaml> [\"<text>\"]"
            + " [--app <name>] [--no-prompts] [--quiet]")
        exit(2)
    }
    let text = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
        ? arguments[index + 2] : nil
    exit(PipelineCommand.run(
        path: arguments[index + 1], text: text,
        quiet: arguments.contains("--quiet"), app: appArgument,
        allowPrompts: !arguments.contains("--no-prompts"),
        showVars: arguments.contains("--vars")
    ))
}

if let index = arguments.firstIndex(of: "--dates") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --dates \"<instruction>\" \"<text>\" [--quiet]")
        exit(2)
    }
    exit(DatesCommand.run(
        instruction: arguments[index + 1],
        text: arguments[index + 2],
        quiet: arguments.contains("--quiet"),
        languages: languageList(arguments),
        region: arguments.firstIndex(of: "--locale").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
    ))
}

if let index = arguments.firstIndex(of: "--learn") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --learn <heard> <corrected> [kind] [--in \"<sentence>\"]")
        exit(2)
    }
    let kind = arguments.indices.contains(index + 3)
        ? WordKind(rawValue: arguments[index + 3]) : nil
    let sentence = arguments.firstIndex(of: "--in").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    }
    exit(LearnCommand.run(heard: arguments[index + 1], corrected: arguments[index + 2],
                          kind: kind, sentence: sentence))
}

if let index = arguments.firstIndex(of: "--for") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --for <term> \"<sentence>\" [word]")
        exit(2)
    }
    let span = arguments.indices.contains(index + 3)
        && !arguments[index + 3].hasPrefix("--") ? arguments[index + 3] : nil
    exit(LearnCommand.supporting(
        term: arguments[index + 1], sentence: arguments[index + 2], span: span
    ))
}

if let index = arguments.firstIndex(of: "--forget") {
    guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
        print("usage: ParrotFlow --forget <term>")
        exit(2)
    }
    exit(ForgetCommand.run(term: arguments[index + 1]))
}

if let index = arguments.firstIndex(of: "--profile") {
    guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
        print("usage: ParrotFlow --profile <bundle-id> [name]")
        exit(2)
    }
    let name = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
        ? arguments[index + 2] : ""
    exit(ProfileCommand.run(bundleID: arguments[index + 1], name: name))
}

if let index = arguments.firstIndex(of: "--peek") {
    let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) : nil
    let sentinel = arguments.firstIndex(of: "--find").flatMap { found in
        arguments.indices.contains(found + 1) ? arguments[found + 1] : nil
    }
    exit(PeekCommand.run(
        seconds: seconds ?? 3, expecting: sentinel,
        viaCopy: arguments.contains("--via-copy")
    ))
}

if let index = arguments.firstIndex(of: "--context-test") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --context-test \"<screen>\" [limit]")
        exit(2)
    }
    let limit = arguments.indices.contains(index + 2)
        ? Int(arguments[index + 2]) : nil
    exit(ContextTestCommand.run(
        screen: arguments[index + 1], limit: limit ?? Context.maxChars
    ))
}

if let index = arguments.firstIndex(of: "--portrait") {
    guard #available(macOS 14, *) else {
        print("✗ portraits need macOS 14 or later")
        exit(1)
    }
    guard arguments.indices.contains(index + 1) else {
        exit(TermPortraitCommand.all())
    }
    let sentence = arguments.indices.contains(index + 2) ? arguments[index + 2] : nil
    let span = arguments.indices.contains(index + 3) ? arguments[index + 3] : nil
    exit(TermPortraitCommand.run(term: arguments[index + 1], sentence: sentence, span: span))
}

if let index = arguments.firstIndex(of: "--slot-gap") {
    guard #available(macOS 14, *) else {
        print("✗ the slot reference needs macOS 14 or later")
        exit(1)
    }
    guard arguments.indices.contains(index + 3) else {
        print("usage: ParrotFlow --slot-gap \"<sentence>\" <heard> <term>")
        exit(2)
    }
    exit(
        SlotGapCommand.run(
            sentence: arguments[index + 1],
            heard: arguments[index + 2],
            term: arguments[index + 3]
        )
    )
}

if let index = arguments.firstIndex(of: "--word-vector") {
    guard #available(macOS 14, *) else {
        print("✗ word vectors need macOS 14 or later")
        exit(1)
    }
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --word-vector \"<sentence>\" <word> [--around]")
        exit(2)
    }
    exit(
        WordVectorCommand.run(
            sentence: arguments[index + 1],
            word: arguments[index + 2],
            around: arguments.contains("--around")
        )
    )
}

if let index = arguments.firstIndex(of: "--tag") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --tag \"<text>\" [--lang fr]")
        exit(2)
    }
    exit(TagCommand.run(text: arguments[index + 1], language: languageList(arguments)?.first))
}

if let index = arguments.firstIndex(of: "--input-test") {
    let usage = "usage: ParrotFlow --input-test \"<field>\" <caret> [selected] [limit]"
    guard arguments.indices.contains(index + 2),
          let caret = Int(arguments[index + 2]) else {
        print(usage)
        exit(2)
    }
    let selected = arguments.indices.contains(index + 3)
        ? (Int(arguments[index + 3]) ?? 0) : 0
    let limit = arguments.indices.contains(index + 4)
        ? Int(arguments[index + 4]) : nil
    // All three are offsets or lengths into a string. A negative one traps
    // rather than misbehaving, so it is refused here and not clamped: a
    // clamped caret would print a cut nobody asked for and look right.
    guard caret >= 0, selected >= 0, (limit ?? 0) >= 0 else {
        print(usage)
        print("caret, selected and limit must not be negative")
        exit(2)
    }
    exit(InputTestCommand.run(
        field: arguments[index + 1], caret: caret, selected: selected,
        limit: limit ?? InputBox.maxChars
    ))
}

if let index = arguments.firstIndex(of: "--compose") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --compose \"<template>\" [name=value ...]")
        exit(2)
    }
    exit(ComposeCommand.run(
        template: arguments[index + 1],
        assignments: Array(arguments[(index + 2)...]).filter { $0.contains("=") }
    ))
}

if let index = arguments.firstIndex(of: "--span-test") {
    guard arguments.indices.contains(index + 3),
          let start = Int(arguments[index + 1]), let length = Int(arguments[index + 2]) else {
        print("usage: ParrotFlow --span-test <start> <length> <replacement> --find <sentinel> [--after <seconds>]")
        exit(2)
    }
    guard let found = arguments.firstIndex(of: "--find"),
          arguments.indices.contains(found + 1) else {
        print("✗ --find <sentinel> is required; it is what stops this writing into a real window")
        exit(2)
    }
    let seconds = arguments.firstIndex(of: "--after").flatMap { after in
        arguments.indices.contains(after + 1) ? Double(arguments[after + 1]) : nil
    }
    let dictated = arguments.firstIndex(of: "--dictated").flatMap { said in
        arguments.indices.contains(said + 1) ? arguments[said + 1] : nil
    }
    exit(EditTestCommand.runSpan(
        start: start, length: length,
        replacement: arguments[index + 3],
        sentinel: arguments[found + 1],
        dictated: dictated,
        seconds: seconds ?? 3
    ))
}

if let index = arguments.firstIndex(of: "--edit-test") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --edit-test <needle> <replacement> --find <sentinel> [--after <seconds>]")
        exit(2)
    }
    guard let found = arguments.firstIndex(of: "--find"),
          arguments.indices.contains(found + 1) else {
        // Not a defaultable argument. Without it this writes into whatever is
        // frontmost, which during a test run is as likely to be a real window.
        print("✗ --find <sentinel> is required; it is what stops this writing into a real window")
        exit(2)
    }
    let seconds = arguments.firstIndex(of: "--after").flatMap { after in
        arguments.indices.contains(after + 1) ? Double(arguments[after + 1]) : nil
    }
    let dictated = arguments.firstIndex(of: "--dictated").flatMap { said in
        arguments.indices.contains(said + 1) ? arguments[said + 1] : nil
    }
    exit(EditTestCommand.run(
        needle: arguments[index + 1],
        replacement: arguments[index + 2],
        sentinel: arguments[found + 1],
        dictated: dictated,
        literal: arguments.contains("--literal"),
        seconds: seconds ?? 3
    ))
}

if arguments.contains("--clipboard-test") {
    exit(ClipboardTestCommand.run())
}

if let index = arguments.firstIndex(of: "--paste-probe") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --paste-probe <plain|markdown|html|rtf|all>"
            + " [--file <fixture.md>] [--bare] [--show]")
        exit(2)
    }
    var file: String?
    if let found = arguments.firstIndex(of: "--file") {
        // Not defaulted back to the built-in fixture. You asked to measure your
        // own document; measuring a different one and saying nothing is how a
        // matrix gets filled with the wrong numbers.
        guard arguments.indices.contains(found + 1) else {
            print("✗ --file needs a path; without one this would score the built-in fixture")
            exit(2)
        }
        file = arguments[found + 1]
    }
    exit(PasteProbeCommand.run(
        flavour: arguments[index + 1],
        file: file,
        bare: arguments.contains("--bare"),
        show: arguments.contains("--show")
    ))
}

if arguments.contains("--span-rule") {
    exit(SpanRuleCommand.run())
}

if arguments.contains("--sound") {
    let code = await SoundCommand.run()
    exit(code)
}

if let index = arguments.firstIndex(of: "--phonemes") {
    // Up to the first flag, not "everything that is not a flag" — the second
    // reading keeps `fr` out of `--lang fr` and phonemises it as a word.
    let words = Array(arguments[(index + 1)...].prefix { !$0.hasPrefix("--") })
    guard !words.isEmpty else {
        print("usage: ParrotFlow --phonemes <word> [word …] [--lang fr]")
        exit(2)
    }
    let language = languageList(arguments)?.first ?? "en"
    let code = await SoundBenchCommand.run(words, language: language)
    exit(code)
}

if let index = arguments.firstIndex(of: "--panel-sheet") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --panel-sheet <out.png>")
        exit(2)
    }
    exit(PanelsCommand.sheet(to: arguments[index + 1]))
}

if let index = arguments.firstIndex(of: "--panels") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --panels <notice|caution|failure|thinking|offer|vocabulary|punctuation|rule|dictation|preview|pill|update|sequence> [seconds]")
        exit(2)
    }
    let seconds = arguments.indices.contains(index + 2) ? Double(arguments[index + 2]) : nil
    exit(PanelsCommand.run(surface: arguments[index + 1], seconds: seconds ?? 20))
}

if arguments.contains("--update-install") {
    exit(UpdateInstallCommand.run(dryRun: arguments.contains("--dry-run")))
}

if arguments.contains("--update-check") {
    let after = arguments.firstIndex(of: "--after-days").flatMap { index in
        arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
    }
    exit(UpdateCheckCommand.run(afterDays: after))
}

if let index = arguments.firstIndex(of: "--watch-modifiers") {
    let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) : nil
    exit(WatchModifiersCommand.run(seconds: seconds ?? 10))
}

if let index = arguments.firstIndex(of: "--watch-taps") {
    // The configured key and delay by default, since what this answers is
    // whether the gesture works on the hotkey you actually use.
    let loaded = (try? ConfigStore.load()) ?? Config()
    let key = arguments.indices.contains(index + 1) && !arguments[index + 1].hasPrefix("-")
        ? arguments[index + 1]
        : loaded.hotkey.key
    let seconds = arguments.indices.contains(index + 2) ? Double(arguments[index + 2]) : nil
    exit(WatchModifiersCommand.taps(
        key: key, seconds: seconds ?? 10, pressDelay: loaded.hotkey.pressDelaySeconds
    ))
}

// A flag nobody claimed is a mistake, not a request to start the app. Falling
// through launched a second copy of ParrotFlow every time a check script ran an
// older binary that did not know the flag yet — four of them, one afternoon.
// What `AppDelegate` reads for itself once the app is up.
let appFlags: Set<String> = ["--preview-panel", "--preview-transform", "--empty"]
if let unknown = arguments.dropFirst().first(where: {
    $0.hasPrefix("--") && !appFlags.contains($0)
}) {
    print("✗ unknown option \(unknown)")
    print("run ParrotFlow with no arguments to start the app")
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only — no Dock icon, no app switcher entry.
app.setActivationPolicy(.accessory)
app.run()
