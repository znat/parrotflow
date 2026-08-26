import AppKit
import Foundation

/// `--watch-modifiers [seconds]` — prints which modifier keys are physically
/// down, live. The quickest way to confirm that a bare-modifier hotkey is being
/// seen, and that left and right are actually distinguishable on your keyboard.
enum WatchModifiersCommand {

    static func run(seconds: Double) -> Int32 {
        print("Hold modifier keys — Right ⌥, Left ⌘, fn… (\(Int(seconds))s)")
        print("Nothing appearing? Then the flag state isn't reaching this process.\n")

        var lastFlags: UInt64 = .max
        var everSaw: Set<ModifierKey> = []
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            let flags = ModifierKey.currentFlags
            if flags != lastFlags {
                lastFlags = flags
                let held = ModifierKey.allCases.filter { $0.isPressed }
                everSaw.formUnion(held)

                let names = held.isEmpty ? "—" : held.map(\.displayName).joined(separator: "  ")
                print(String(format: "  0x%08llx   %@", flags, names))
            }
            // Same cadence the real monitor polls at.
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }

        print("")
        if everSaw.isEmpty {
            print("✗ no modifier keys detected")
            return 1
        }
        print("✓ detected: \(everSaw.map(\.displayName).sorted().joined(separator: ", "))")
        return 0
    }

    /// `--watch-taps <key> [seconds]` — the same key through the real
    /// `ModifierKeyMonitor`, printing which edge each press came out as.
    ///
    /// A tap cannot be scored from a fixture: it is a length of time on a
    /// physical key, and what makes it hard is that a shortcut looks like one
    /// until the second key arrives. So this is the surface for it — press the
    /// key alone and it says `tap`; press ⌘S and it says nothing at all, which
    /// is the case worth checking.
    static func taps(key name: String, seconds: Double, pressDelay: TimeInterval) -> Int32 {
        guard let key = ModifierKey(name: name) else {
            print("✗ \"\(name)\" is not a bare modifier — see docs/configuration.md")
            return 1
        }
        print("Tap \(key.displayName), hold it, and try a shortcut with it (\(Int(seconds))s)")
        print("press_delay is \(pressDelay)s — shorter than that is a tap.\n")

        let monitor = ModifierKeyMonitor()
        var counts: [String: Int] = [:]
        func note(_ edge: String) {
            counts[edge, default: 0] += 1
            print("  \(edge)")
        }
        monitor.onPress = { note("press   — a dictation would start here") }
        monitor.onRelease = { note("release — and end here") }
        monitor.onAbort = { note("abort   — that was a shortcut") }
        monitor.onTap = { note("tap     — the offer would be summoned") }
        monitor.start(key: key, pressDelay: pressDelay)

        // Pumped in slices so the key can be sampled alongside the monitor. An
        // edge that never arrives has three causes and they need different
        // answers — nothing was pressed, the flags never reached us, or every
        // hold was somebody's shortcut — and a summary that cannot tell them
        // apart sends you looking at the wrong one. Same cadence the monitor
        // polls at, so a press cannot fall between two samples.
        var samples = 0
        var sawDown = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            samples += 1
            if key.isPressed { sawDown += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        monitor.stop()

        print("")
        guard samples > 1 else {
            print("✗ the run loop never pumped — no key could have been seen")
            return 1
        }
        guard sawDown > 0 else {
            print("✗ \(key.displayName) was never down in those \(Int(seconds))s")
            print("  Either it was not pressed, or the flag state is not reaching this")
            print("  process — `--watch-modifiers` says which.")
            return 1
        }
        guard !counts.isEmpty else {
            print("✗ \(key.displayName) went down \(sawDown) sample(s) and produced no edge")
            print("  Every hold was ruled out as a shortcut: something else was pressed,")
            print("  clicked or scrolled while it was held. See `press_delay_seconds`.")
            return 1
        }
        for edge in counts.keys.sorted() {
            print("  \(counts[edge] ?? 0)× \(edge.split(separator: " ")[0])")
        }
        return 0
    }
}
