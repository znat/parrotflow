import AppKit

// Terminal entry points, mostly for diagnosing "why isn't it recording":
//
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --record 3
//   ParrotFlow.app/Contents/MacOS/ParrotFlow --transcribe clip.wav
//
let arguments = CommandLine.arguments

if arguments.contains("--check-config") {
    exit(CheckConfigCommand.run())
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
        print("usage: ParrotFlow --replace \"<text>\"")
        exit(2)
    }
    exit(ReplaceCommand.run(text: arguments[index + 1]))
}

if let index = arguments.firstIndex(of: "--numbers") {
    let text = arguments.indices.contains(index + 1) && !arguments[index + 1].hasPrefix("--")
        ? arguments[index + 1] : nil
    let language = arguments.firstIndex(of: "--lang").flatMap { index in
        arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    }
    exit(NumbersCommand.run(
        text: text, quiet: arguments.contains("--quiet"), language: language
    ))
}

if let index = arguments.firstIndex(of: "--normalize") {
    let text = arguments.indices.contains(index + 1) && !arguments[index + 1].hasPrefix("--")
        ? arguments[index + 1] : nil
    exit(NormalizeCommand.run(text: text))
}

if let index = arguments.firstIndex(of: "--command") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --command \"hey parrot, Tasmin spells T A S M E E N\"")
        exit(2)
    }
    let context = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
        ? arguments[index + 2] : nil
    exit(CommandTestCommand.run(text: arguments[index + 1], lastTranscript: context))
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

if let index = arguments.firstIndex(of: "--dates") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --dates \"<instruction>\" \"<text>\" [--quiet]")
        exit(2)
    }
    exit(DatesCommand.run(
        instruction: arguments[index + 1],
        text: arguments[index + 2],
        quiet: arguments.contains("--quiet")
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
    exit(PeekCommand.run(seconds: seconds ?? 3, expecting: sentinel))
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
