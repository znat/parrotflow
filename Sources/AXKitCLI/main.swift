import AXKit
import AppKit
import Foundation

let usage = """
usage: axkit trusted
       axkit apps
       axkit dump  (--app <name or bundle> | --pid <n> | --front) [--all-windows] [--wake]
                   [--depth n] [--budget n] [--json]
       axkit find  (--app … | --pid … | --front) [--role AXButton] [--name <glob>] [--dom <id>]
                   [--wake] [--json]
       axkit hit   <x> <y> [--app … | --pid …] [--json]
       axkit traits [--bundle <id>] [<operation> …] [--json]    what each operation asks of the user,
                   native or in the app's pages; with operations, the warning for running them together
       axkit check [--json] [--popups] [--keyboard]    plays the control matrix on the fixture window, in the background
       axkit check --web [--page <index.html>] [--json]    the same on the web page, in a throwaway Chrome
       axkit check --electron [--folder <app>] [--json]    Teams and Slack patterns, in an Electron window
       axkit check --share [--json]    File > Share > Messages, then Cancel: a foreground check, nothing sent
       axkit check --system [--json]    Dock badge, menu bar icon, text and copy between apps, open with
       axkit check --apps [--json]    Calculator and a file opened in the background, then quit
       axkit check --layout [--fullscreen] [--json]    fixture windows in halves and thirds on each screen, in the background
       axkit check --drag [--json]    a file dragged from the Finder, in the foreground: hands off the mouse
"""

/// Closes what a check opened: `fail` exits without running `defer`, and a
/// fixture left open blocks the next run (one Electron per profile).
var cleanups: [() -> Void] = []

/// A locked screen hides every window's contents and refuses keys: whatever
/// a check measures after it is meaningless, so the check stops there.
func stopIfLocked() {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    if (session["CGSSessionScreenIsLocked"] as? Bool) == true {
        fail("the screen is locked: the check stops here, and what follows would measure nothing")
    }
}

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    cleanups.reversed().forEach { $0() }
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage, 2) }
arguments.removeFirst()

func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func has(_ flag: String) -> Bool { arguments.contains(flag) }

func printJSON<T: Encodable>(_ thing: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(data: try! encoder.encode(thing), encoding: .utf8)!)
}

func target() -> App? {
    if let pid = value("--pid").flatMap(Int32.init) { return App(pid: pid) }
    if let name = value("--app") {
        guard let app = App.named(name) else { fail(AXKitError.appNotFound(name).description) }
        return app
    }
    if has("--front") { return App.frontmost }
    return nil
}

func options() -> WalkOptions {
    var options = WalkOptions()
    if let depth = value("--depth").flatMap(Int.init) { options.depth = depth }
    if let budget = value("--budget").flatMap(Int.init) { options.budget = budget }
    return options
}

func line(_ node: Node) -> String {
    var parts = [String(repeating: "  ", count: node.depth) + node.role]
    if let subrole = node.subrole { parts[0] += "/" + subrole }
    if let name = node.name { parts.append("\"\(name)\"") }
    if let value = node.value { parts.append("= \"\(value.replacingOccurrences(of: "\n", with: " "))\"") }
    if let dom = node.dom { parts.append("#\(dom)") }
    if !node.states.isEmpty { parts.append("[\(node.states.joined(separator: ","))]") }
    if let frame = node.frame { parts.append("@\(frame.x),\(frame.y) \(frame.w)x\(frame.h)") }
    return parts.joined(separator: " ")
}

if !["trusted", "apps", "traits"].contains(command) && !App.isTrusted {
    fail(AXKitError.notTrusted.description + " (the terminal running this needs it)")
}

switch command {
case "trusted":
    print(App.isTrusted)

case "apps":
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        print("\(app.processIdentifier)\t\(app.bundleIdentifier ?? "")\t\(app.localizedName ?? "")")
    }

case "dump":
    guard let app = target() else { fail(usage, 2) }
    if has("--wake") { app.wake() }
    let roots = has("--all-windows") ? app.windows : [app.focusedWindow ?? app.element]
    let results = roots.map { Walk.run(from: $0, options: options()) }
    if has("--json") {
        printJSON(results)
    } else {
        for result in results {
            result.nodes.forEach { print(line($0)) }
            print("-- \(result.nodes.count) elements, \(result.milliseconds) ms"
                  + (result.stopped.map { ", stopped by \($0)" } ?? ""))
        }
    }

case "find":
    guard let app = target() else { fail(usage, 2) }
    if has("--wake") { app.wake() }
    let root = app.focusedWindow ?? app.element
    let found = Walk.find(in: root, role: value("--role"), name: value("--name"), dom: value("--dom"),
                          options: options()).map(\.1)
    if has("--json") { printJSON(found) } else { found.forEach { print(line($0)) } }

case "hit":
    guard arguments.count >= 2, let x = Double(arguments[0]), let y = Double(arguments[1]) else {
        fail(usage, 2)
    }
    let point = CGPoint(x: x, y: y)
    let app = target()
    guard let element = app?.element(at: point) ?? App.element(at: point) else { fail("nothing at \(x),\(y)") }
    let node = Walk.run(from: element, options: WalkOptions(depth: 1)).nodes.first
    if has("--json") { printJSON(node) } else { node.map { print(line($0)) } }

case "traits":
    exit(TraitsCommand.run(arguments, bundle: value("--bundle"), json: has("--json")))

case "check" where has("--share"):
    exit(ShareCheck.run(json: has("--json")))

case "check" where has("--system"):
    exit(SystemCheck.run(json: has("--json")))

case "check" where has("--apps"):
    exit(AppsCheck.run(json: has("--json")))

case "check" where has("--layout"):
    exit(LayoutCheck.run(json: has("--json"), fullScreen: has("--fullscreen")))

case "check" where has("--drag"):
    exit(DragCheck.run(json: has("--json"), only: value("--only")))

case "check" where has("--electron"):
    let folder = value("--folder") ?? FileManager.default.currentDirectoryPath + "/Fixtures/electron-app"
    exit(ElectronCheck.run(folder: folder, json: has("--json"), only: value("--only")))

case "check" where has("--web"):
    let page = value("--page") ?? FileManager.default.currentDirectoryPath + "/Fixtures/web-controls/index.html"
    exit(WebCheck.run(page: page, json: has("--json"), only: value("--only"), keys: !has("--no-keys")))

case "check" where value("--repeat") != nil:
    exit(Check.repeated(Int(value("--repeat")!) ?? 5, popups: has("--popups"), keyboard: has("--keyboard")))

case "check":
    exit(Check.run(json: has("--json"), popups: has("--popups"), keyboard: has("--keyboard")))

default:
    fail(usage, 2)
}
