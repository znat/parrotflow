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

if let index = arguments.firstIndex(of: "--command") {
    guard arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --command \"hey parrot, Tasmin spells T A S M E E N\"")
        exit(2)
    }
    let context = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
        ? arguments[index + 2] : nil
    exit(CommandTestCommand.run(text: arguments[index + 1], lastTranscript: context))
}

if let index = arguments.firstIndex(of: "--learn") {
    guard arguments.indices.contains(index + 2) else {
        print("usage: ParrotFlow --learn <heard> <corrected>")
        exit(2)
    }
    exit(LearnCommand.run(heard: arguments[index + 1], corrected: arguments[index + 2]))
}

if let index = arguments.firstIndex(of: "--spot") {
    guard #available(macOS 14, *), arguments.indices.contains(index + 1) else {
        print("usage: ParrotFlow --spot <file.wav> [minScore]")
        exit(2)
    }
    let score = arguments.indices.contains(index + 2) ? Float(arguments[index + 2]) : nil
    exit(SpotCommand.run(path: arguments[index + 1], minScore: score))
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
