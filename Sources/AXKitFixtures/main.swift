import AppKit

// AXKitFixtures [seconds] [--state <path>] [--background]
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
    let seconds = arguments.first.flatMap(Double.init) ?? 600

    let app = NSApplication.shared
    let surface = ControlsSurface(statePath: statePath)
    surface.show(background: background)
    print("controls: pid \(ProcessInfo.processInfo.processIdentifier), state \(statePath)")
    fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    withExtendedLifetime(surface) { app.run() }
}
