import AppKit
import CoreGraphics

/// A modifier used *alone* as the hotkey — Right ⌥, Right ⌘, fn, and friends.
///
/// `RegisterEventHotKey` can't express these (it wants a character key plus a
/// modifier mask), so they get a separate backend that polls the global
/// modifier state. `CGEventSource.flagsState` is a plain read of the current
/// session's flags: no Accessibility permission, no event tap, no keystroke
/// monitoring prompt.
enum ModifierKey: String, CaseIterable {
    case rightOption
    case leftOption
    case rightCommand
    case leftCommand
    case rightControl
    case leftControl
    case rightShift
    case leftShift
    case function

    /// Device-dependent masks from `IOKit/hidsystem/IOLLEvent.h`. The ordinary
    /// `NSEvent.ModifierFlags` constants only say "option" — these are what
    /// distinguish the left key from the right one.
    var mask: UInt64 {
        switch self {
        case .leftControl:  return 0x0000_0001  // NX_DEVICELCTLKEYMASK
        case .leftShift:    return 0x0000_0002  // NX_DEVICELSHIFTKEYMASK
        case .rightShift:   return 0x0000_0004  // NX_DEVICERSHIFTKEYMASK
        case .leftCommand:  return 0x0000_0008  // NX_DEVICELCMDKEYMASK
        case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .leftOption:   return 0x0000_0020  // NX_DEVICELALTKEYMASK
        case .rightOption:  return 0x0000_0040  // NX_DEVICERALTKEYMASK
        case .rightControl: return 0x0000_2000  // NX_DEVICERCTLKEYMASK
        case .function:     return 0x0080_0000  // NX_SECONDARYFNMASK
        }
    }

    var isPressed: Bool {
        Self.currentFlags & mask == mask
    }

    static var currentFlags: UInt64 {
        CGEventSource.flagsState(.combinedSessionState).rawValue
    }

    var displayName: String {
        switch self {
        case .rightOption:  return "Right ⌥"
        case .leftOption:   return "Left ⌥"
        case .rightCommand: return "Right ⌘"
        case .leftCommand:  return "Left ⌘"
        case .rightControl: return "Right ⌃"
        case .leftControl:  return "Left ⌃"
        case .rightShift:   return "Right ⇧"
        case .leftShift:    return "Left ⇧"
        case .function:     return "fn"
        }
    }

    /// Accepts the spellings people actually write: `right_option`, `ropt`,
    /// `right-alt`, `rightOption`, `fn`, `globe`.
    init?(name: String) {
        let normalized = name.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "rightoption", "rightalt", "ropt", "ralt", "roption":
            self = .rightOption
        case "leftoption", "leftalt", "lopt", "lalt", "loption":
            self = .leftOption
        case "rightcommand", "rightcmd", "rcmd", "rcommand":
            self = .rightCommand
        case "leftcommand", "leftcmd", "lcmd", "lcommand":
            self = .leftCommand
        case "rightcontrol", "rightctrl", "rctrl", "rcontrol":
            self = .rightControl
        case "leftcontrol", "leftctrl", "lctrl", "lcontrol":
            self = .leftControl
        case "rightshift", "rshift":
            self = .rightShift
        case "leftshift", "lshift":
            self = .leftShift
        case "fn", "function", "globe":
            self = .function
        default:
            return nil
        }
    }
}

/// Edge-detects a single modifier key by polling the global flag state.
///
/// Polling rather than an event tap is a deliberate trade: it costs a cheap
/// read every 25 ms and gives up the ability to swallow the keystroke, in
/// exchange for needing no permissions at all. A bare modifier types nothing on
/// its own, so there is nothing to swallow.
final class ModifierKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var timer: Timer?
    private var isDown = false

    var isMonitoring: Bool { timer != nil }

    func start(key: ModifierKey) {
        stop()
        // Treat a key that is already held at registration time as "down", so a
        // config reload mid-press doesn't fire a spurious edge.
        isDown = key.isPressed

        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self else { return }
            let down = key.isPressed
            guard down != self.isDown else { return }
            self.isDown = down
            if down { self.onPress?() } else { self.onRelease?() }
        }
        // .common so the key keeps working while a menu is open or a window is
        // being dragged — .default timers stall during those tracking loops.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isDown = false
    }

    deinit { stop() }
}
