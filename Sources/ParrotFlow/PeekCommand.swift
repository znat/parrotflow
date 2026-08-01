import AppKit
import ApplicationServices

/// `--peek [seconds]` — reports what the accessibility API can see in whatever
/// app is frontmost, and which write-back branch that would force.
///
/// In-place editing is the one part of this app that cannot be exercised from
/// the terminal alone. Everything else is text in, text out; this depends
/// entirely on the target app, and the apps that matter answer differently. A
/// terminal hands back its whole screen as a read-only value. Electron hands
/// back no selection at all. From inside ParrotFlow the two are indistinguish-
/// able until something has been written and has landed in the wrong place.
///
/// The delay is the whole interface: reading the focused element means not
/// being focused. Run it, click the window you want to inspect, and it prints
/// what the write path would find there.
enum PeekCommand {

    /// Everything goes to the log as well as stdout.
    ///
    /// Not for posterity — it is the only transport that works. TCC pins the
    /// accessibility grant to the bundle, and a binary spawned from a terminal
    /// is attributed to the terminal instead, so the only way to run this with
    /// the app's own identity is `open -na ParrotFlowDev --args --peek`, and
    /// LaunchServices throws stdout away. A harness reads the log.
    private static func report(_ line: String) {
        print(line)
        Log.write("peek: \(line)")
    }

    /// `expecting` is the harness's precondition, not a convenience.
    ///
    /// Everything here reads whatever window happens to be frontmost, and the
    /// wrong window answers just as confidently as the right one — a peek at a
    /// stray shell reports a perfectly good `AXTextArea` and means nothing. So
    /// a harness seeds a sentinel through tmux and names it here: if it is not
    /// in the value, accessibility and the pane are not looking at the same
    /// place and every measurement after this point is fiction.
    static func run(seconds: Double, expecting sentinel: String? = nil) -> Int32 {
        defer { Log.flush() }

        // Declare ourselves an accessory before anything else. Launched through
        // LaunchServices this process is an ordinary app until it says
        // otherwise, and an ordinary app takes part in activation — so it
        // becomes the focused application, whose focused element is nothing,
        // and the peek reports an empty screen it caused itself.
        NSApplication.shared.setActivationPolicy(.accessory)

        guard Permissions.accessibility == .granted else {
            report("✗ accessibility is not granted to this binary")
            report("  TCC pins the grant to the bundle, so run the copy inside it:")
            report("  /Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --peek")
            return 1
        }

        if seconds > 0 {
            print("focus the window to inspect — reading in \(Int(seconds))s")
            Thread.sleep(forTimeInterval: seconds)
        }

        let front = NSWorkspace.shared.frontmostApplication
        report("app       \(front?.localizedName ?? "unknown")")
        // Not the same question, and when they disagree that is the answer:
        // NSWorkspace reports who is in front, accessibility reports whose
        // element tree it will hand back. A peek that reads nothing while the
        // right app is in front is usually these two pointing at different
        // processes.
        report("ax app    \(focusedApplicationName() ?? "none")")

        guard let element = SelectionReader.focusedElement() else {
            report("element   nothing focused")
            return 1
        }
        guard !SelectionReader.isOurs(element) else {
            report("element   ParrotFlow's own window — focus the target instead")
            return 1
        }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        report("role      \((role as? String) ?? "unknown")")

        let value = SelectionReader.visibleText(of: element)
        if let value {
            let lines = value.components(separatedBy: "\n").count
            report("value     \(value.count) chars, \(lines) line(s)")
            report("tail      \"\(preview(value))\"")
        } else {
            report("value     unreadable")
        }

        let selected = SelectionReader.selectedText(of: element)
        // The decision a retype turns on: whether the input box can be found at
        // all, and what it reads once its rows are joined back together.
        if let value {
            if let box = SelectionReader.joinedInputBox(in: value) {
                report("box       \(box.count) chars — \"\(preview(box))\"")
            } else {
                report("box       none — no pair of rules to read between")
            }
            // Which rows the box reader counts as rules. The heuristic is
            // "between the last two", and when that picks the wrong pair the
            // box reads empty while the text is plainly on screen.
            report("rows      (rule = counted as a boundary)")
            for row in value.components(separatedBy: "\n").suffix(14) {
                let kind = SelectionReader.isBorder(row) ? "rule" : "    "
                report("  \(kind)  |\(row.prefix(64))|")
            }
        }
        report("selected  \(selected.map { "\"\(preview($0))\"" } ?? "none")")
        report("range     \(rangeDescription(of: element))")

        if let sentinel {
            guard let value, value.contains(sentinel) else {
                report("sentinel  \"\(sentinel)\" NOT in the focused element — wrong window")
                return 2
            }
            report("sentinel  \"\(sentinel)\" found — accessibility and the pane agree")
        }

        report("")
        report("a write here would:")
        describeBranches(value: value, selected: selected)
        return 0
    }

    /// Mirrors the branch order in `SelectionReader.replaceSelection` and
    /// `rewriteCurrentLine`. Held in step with them by hand — when this and the
    /// write path disagree, this command is the one lying, and the harness
    /// built on top of it is measuring nothing.
    private static func describeBranches(value: String?, selected: String?) {
        // The direct range write is the only branch that cannot be predicted
        // from a read: setting a range returns .success in terminals that then
        // ignore it, which is exactly the lie the write path exists to survive.
        // So this reports what is knowable and says plainly what is not.
        report("  1. try the accessibility range write — unknowable without writing;")
        report("     terminals report success here and change nothing")

        if let selected, !selected.isEmpty {
            report("  2. fall back to pasting over the live selection — available")
        } else {
            report("  2. fall back to pasting over the live selection — refused,")
            report("     no selection to confirm, so it will not paste blind")
        }

        guard let value else {
            report("  3. retyping the input line — unavailable, value unreadable")
            return
        }
        if (try? ConfigStore.load())?.transcription.rewriteLine != true {
            report("  3. retyping the input line — refused, rewrite_line is off")
        } else if value.contains("\n") {
            report("  3. retyping the input line — refused, value is \(value.count) chars")
            report("     of screen, not one field; a terminal never passes this gate")
        } else if value.count > 2000 {
            report("  3. retyping the input line — refused, \(value.count) chars is too long")
        } else {
            report("  3. retyping the input line — available (Ctrl-A, Ctrl-K, paste)")
        }
    }

    /// The application accessibility considers focused, by name.
    private static func focusedApplicationName() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedApplicationAttribute as CFString, &focused
        ) == .success, let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return "\(name) (pid \(pid))"
    }

    private static func rangeDescription(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let wrapped = value, CFGetTypeID(wrapped) == AXValueGetTypeID()
        else { return "none" }

        var range = CFRange()
        guard AXValueGetValue(wrapped as! AXValue, .cfRange, &range) else { return "unreadable" }
        return "location \(range.location), length \(range.length)"
    }

    private static func preview(_ text: String) -> String {
        text.suffix(80).replacingOccurrences(of: "\n", with: "⏎")
    }
}
