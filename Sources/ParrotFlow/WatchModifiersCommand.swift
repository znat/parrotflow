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
}
