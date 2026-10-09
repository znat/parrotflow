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
       axkit read  (--app … | --pid … | --front) [--depth n] [--budget n]
                   [--records | --text | --json]
"""

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
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

func count(_ flag: String) -> Int? {
    guard has(flag) else { return nil }
    guard let raw = value(flag), let number = Int(raw), number >= 0 else {
        fail("\(flag) takes a whole number of zero or more", 2)
    }
    return number
}

func printJSON<T: Encodable>(_ thing: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(thing), let text = String(data: data, encoding: .utf8) else {
        fail("could not encode the result as JSON")
    }
    print(text)
}

func target() -> App? {
    if let raw = value("--pid") {
        guard let pid = Int32(raw) else { fail("--pid takes a process number, not \"\(raw)\"", 2) }
        return App(pid: pid)
    }
    if let name = value("--app") {
        guard let app = App.named(name) else { fail(AXKitError.appNotFound(name).description) }
        return app
    }
    if has("--front") { return App.frontmost }
    return nil
}

func options() -> WalkOptions {
    var options = WalkOptions()
    if let depth = count("--depth") { options.depth = depth }
    if let budget = count("--budget") { options.budget = budget }
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

func line(_ record: Record) -> String {
    var parts = [String(repeating: "  ", count: record.depth) + record.role]
    if let subrole = record.subrole { parts[0] += "/" + subrole }
    for text in [record.title, record.description].compactMap({ $0 }) { parts.append("\"\(text)\"") }
    if let value = record.value { parts.append("= \"\(value.replacingOccurrences(of: "\n", with: " "))\"") }
    if let number = record.number { parts.append("= \(number)") }
    if let url = record.url { parts.append("<\(url)>") }
    if record.focused { parts.append("[focused]") }
    if let frame = record.frame { parts.append("@\(frame.x),\(frame.y) \(frame.w)x\(frame.h)") }
    return parts.joined(separator: " ")
}

if !["trusted", "apps"].contains(command) && !App.isTrusted {
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
    let found = target().map { $0.element(at: point) } ?? App.element(at: point)
    guard let element = found else { fail("nothing at \(x),\(y)") }
    let node = Walk.run(from: element, options: WalkOptions(depth: 1)).nodes.first
    if has("--json") { printJSON(node) } else { node.map { print(line($0)) } }

case "read":
    guard let app = target() else { fail(usage, 2) }
    var options = ReadOptions()
    if let depth = count("--depth") { options.depth = depth }
    if let budget = count("--budget") { options.budget = budget }
    let result = Read.walk(from: app.focusedWindow ?? app.element, options: options)
    if has("--json") {
        printJSON(result)
    } else {
        if has("--records") { result.records.forEach { print(line($0)) } }
        if has("--text") { Read.visibleText(result.records).forEach { print($0) } }
        let nodes = max(result.records.count, 1)
        print(String(format: "-- %d records, %d calls (%.2f per record), %.1f ms (%.3f ms per record), %d failed",
                     result.records.count, result.calls, Double(result.calls) / Double(nodes),
                     result.milliseconds, result.milliseconds / Double(nodes), result.failed)
              + (result.stopped.map { ", stopped by \($0.rawValue)" } ?? ""))
    }

default:
    fail(usage, 2)
}
