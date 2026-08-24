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

    /// Every device-specific bit above, ORed together. Used to ask "is any
    /// modifier other than this one down" — which is the cheap half of telling
    /// a dictation apart from a shortcut, and the only half that needs no
    /// permission.
    static let allDeviceMasks: UInt64 = allCases.reduce(0) { $0 | $1.mask }

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

/// Edge-detects a single modifier key, and refuses the edges that were part of
/// somebody else's shortcut.
///
/// ## Why a bare modifier is never really bare
///
/// The first version of this assumed a modifier alone types nothing, so a
/// press could be taken at face value. That is not true of any modifier on a
/// Mac. ⌘ is half of every shortcut in every app. ⌥ is a live character key on
/// most non-US layouts — on the French layout it is what types `#`, `{`, `|`
/// and `~` — and everywhere it is ⌥← to jump a word and ⌥⌫ to delete one. So
/// the down edge on its own says nothing about whether a dictation was meant.
/// Taken at face value, every ⌘S opened the mic.
///
/// ## What tells them apart
///
/// Held alone, and nothing else touched. A shortcut is a modifier plus
/// something; a dictation is a modifier and then silence on the keyboard.
/// Waiting is what makes the difference visible, so the press is held back for
/// `pressDelay` and only delivered if nothing else happened in that window.
///
/// The wait costs nothing at this end. `release_tail_seconds` exists because
/// the hand beats the mouth on the way *up* — the key is released while the
/// last syllable is still being said. There is no matching problem on the way
/// down: nobody starts a word within 180 ms of pressing the key.
///
/// A shortcut can also be slow — a modifier held while you think, then a click
/// — so the watch does not stop when the press is delivered. Something else
/// arriving after that aborts the dictation instead of never starting it, and
/// `onRelease` does not fire for a hold that was aborted.
///
/// ## What it watches
///
/// Two sources, because they cost different things. Another modifier is read
/// straight out of the flags the poll already reads, so a ⌘⌥ chord is caught
/// with no permission at all. Keys, clicks and scrolls need
/// `NSEvent.addGlobalMonitorForEvents`, which needs Accessibility — already
/// required by the app, and it observes without consuming, so nothing is taken
/// from the app in front. Monitors exist only while the key is down: an idle
/// app is not watching the keyboard.
///
/// Polling rather than an event tap is still a deliberate trade: a cheap read
/// every 25 ms, and no Input Monitoring grant, in exchange for not being able
/// to swallow the keystroke. Nothing here wants to swallow one — the shortcut
/// is meant to work.
///
/// Secure Event Input — what a terminal turns on around a password prompt —
/// hides keys from the monitor the same way it hides them from a tap, so the
/// watch falls back to its modifier half there. Left as is: a modifier held
/// alone is not what happens while somebody is typing a password.
final class ModifierKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// A press that was already delivered turned out to be a shortcut. Whoever
    /// started a dictation on `onPress` has to drop it, silently: the user
    /// pressed ⌘S and is owed a save, not a notice about dictation.
    var onAbort: (() -> Void)?

    private var timer: Timer?
    private var monitors: [Any] = []
    private var armTimer: Timer?

    private var key: ModifierKey?
    private var pressDelay: TimeInterval = 0
    /// The key is physically down.
    private var isDown = false
    /// `onPress` has been delivered for the current hold.
    private var pressDelivered = false
    /// This hold has been ruled out. Stays set until the key comes up, so a
    /// second key in the same shortcut cannot abort twice.
    private var isSpent = false

    var isMonitoring: Bool { timer != nil }

    /// `pressDelay` of 0 restores the old behaviour: the press fires on the
    /// down edge, and only the abort path is left to catch a shortcut.
    func start(key: ModifierKey, pressDelay: TimeInterval = 0) {
        stop()
        self.key = key
        self.pressDelay = pressDelay
        // Treat a key that is already held at registration time as "down", so a
        // config reload mid-press doesn't fire a spurious edge. Spent as well:
        // there is no way to know now what else has been pressed since it went
        // down, and a dictation nobody asked for is worse than one that needs
        // the key pressed again.
        isDown = key.isPressed
        isSpent = isDown

        // The flags half of the watch works regardless; the keys and clicks
        // half does not, and its absence looks exactly like a shortcut that
        // never came. Said once here rather than on every press.
        if Permissions.accessibility != .granted {
            Log.write("hotkey: accessibility is not granted; a shortcut cannot be told from a dictation")
        }

        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common so the key keeps working while a menu is open or a window is
        // being dragged — .default timers stall during those tracking loops.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endHold()
        key = nil
        isDown = false
    }

    deinit { stop() }

    // MARK: The poll

    private func poll() {
        guard let key else { return }
        // One read, used for both questions below.
        let flags = ModifierKey.currentFlags
        let down = flags & key.mask == key.mask

        if down != isDown {
            isDown = down
            if down { beginHold() } else { finishHold() }
            return
        }

        // Held, and another modifier joined it: a chord, not a dictation.
        if down, !isSpent, flags & ModifierKey.allDeviceMasks & ~key.mask != 0 {
            somethingElseHappened()
        }
    }

    private func beginHold() {
        isSpent = false
        pressDelivered = false
        watchForOtherInput()

        guard pressDelay > 0 else {
            deliverPress()
            return
        }
        let timer = Timer(timeInterval: pressDelay, repeats: false) { [weak self] _ in
            self?.armTimer = nil
            self?.deliverPress()
        }
        RunLoop.main.add(timer, forMode: .common)
        armTimer = timer
    }

    private func deliverPress() {
        guard isDown, !isSpent, !pressDelivered else { return }
        pressDelivered = true
        onPress?()
    }

    private func finishHold() {
        let wasPressed = pressDelivered
        endHold()
        if wasPressed { onRelease?() }
    }

    /// The one path out of a hold that was meant for something else. Delivered
    /// as an abort only if a press went out for it — otherwise the press
    /// simply never happens and there is nothing to tell anyone about.
    private func somethingElseHappened() {
        guard !isSpent else { return }
        let wasPressed = pressDelivered
        isSpent = true
        pressDelivered = false
        armTimer?.invalidate(); armTimer = nil
        // Nothing more to learn from this hold, so the monitors go now rather
        // than at the release.
        removeMonitors()
        if wasPressed { onAbort?() }
    }

    private func endHold() {
        armTimer?.invalidate(); armTimer = nil
        removeMonitors()
        pressDelivered = false
        isSpent = false
    }

    // MARK: Watching for everything that is not the key

    private func watchForOtherInput() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        let sawInput: (NSEvent) -> Void = { [weak self] event in
            // A flick that ended before the key went down keeps sending scroll
            // events for about a second afterwards. Coasting is not an action,
            // and treating it as one would abort a dictation started right
            // after scrolling a page.
            guard event.type != .scrollWheel || event.momentumPhase.isEmpty else { return }
            self?.somethingElseHappened()
        }
        // The global monitor sees events while another app is in front, which
        // is every ordinary dictation. The local one sees them while a panel of
        // ours is up. Neither consumes anything.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: sawInput) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            sawInput(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }
}
