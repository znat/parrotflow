import AppKit

// Terminal entry points, mostly for diagnosing "why isn't it recording":
//
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --record 3
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --transcribe clip.wav
//
let arguments = CommandLine.arguments

// Log writes are asynchronous, which is right for a menu bar app and wrong for
// a command that exits the moment it has printed: the process is gone before
// the queue drains and the lines are silently lost. Two commands remembered to
// flush and the rest did not, so `--replace` was dropping the very lines that
// explain what the pipeline did — a stage saying it skipped, and why. Doing it
// here covers every path, including the ones added later.
atexit { Log.flush(); Trace.flush() }

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

/// `--app <name>`, for the commands that run a pipeline. Shared so the flag
/// means the same thing to each of them.
let appArgument: String? = arguments.firstIndex(of: "--app").flatMap { index in
    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
}

if let index = arguments.firstIndex(of: "--record") {
    let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) : nil
    exit(RecordTestCommand.run(seconds: seconds ?? 3))
}

if let index = arguments.firstIndex(of: "--transcribe") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --transcribe <file.wav>")
        exit(2)
    }
    exit(TranscribeCommand.run(path: arguments[index + 1]))
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
        print("usage: ParrotFlow --route \"hey parrot, make that a bullet list\" [--quiet]")
        exit(2)
    }
    exit(RouteTestCommand.run(
        text: arguments[index + 1], quiet: arguments.contains("--quiet")
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
        print("usage: ParrotFlow --learn <heard> <corrected>")
        exit(2)
    }
    exit(LearnCommand.run(heard: arguments[index + 1], corrected: arguments[index + 2]))
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

if let index = arguments.firstIndex(of: "--panel-sheet") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --panel-sheet <out.png>")
        exit(2)
    }
    exit(PanelsCommand.sheet(to: arguments[index + 1]))
}

if let index = arguments.firstIndex(of: "--panels") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --panels <notice|caution|failure|thinking|vocabulary|rule|preview|pill> [seconds]")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only — no Dock icon, no app switcher entry.
app.setActivationPolicy(.accessory)
app.run()
