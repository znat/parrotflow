import AppKit

// AXKitFixtures [seconds] [--state <path>] [--background] [--title T] [--min-size W H] [--stubborn] [--badge N]
// A window of native controls whose values go to a JSON file on each change.
MainActor.assumeIsolated {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var statePath = ControlsSurface.defaultStatePath
    if let index = arguments.firstIndex(of: "--state"), index + 1 < arguments.count {
        statePath = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
    }
    let background = arguments.contains("--background")
    arguments.removeAll { $0 == "--background" }
    let stubborn = arguments.contains("--stubborn")
    arguments.removeAll { $0 == "--stubborn" }
    var title = "Controls"
    if let index = arguments.firstIndex(of: "--title"), index + 1 < arguments.count {
        title = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
    }
    var badge: String?
    if let index = arguments.firstIndex(of: "--badge"), index + 1 < arguments.count {
        badge = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
    }
    var minimum: NSSize?
    if let index = arguments.firstIndex(of: "--min-size"), index + 2 < arguments.count,
       let width = Double(arguments[index + 1]), let height = Double(arguments[index + 2]) {
        minimum = NSSize(width: width, height: height)
        arguments.removeSubrange(index...index + 2)
    }
    let seconds = arguments.first.flatMap(Double.init) ?? 600

    let app = NSApplication.shared
    let surface = ControlsSurface(statePath: statePath)
    surface.title = title
    surface.minimum = minimum
    surface.refusesMoves = stubborn
    surface.badge = badge
    surface.show(background: background)
    print("controls: pid \(ProcessInfo.processInfo.processIdentifier), state \(statePath)")
    fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    withExtendedLifetime(surface) { app.run() }
}
