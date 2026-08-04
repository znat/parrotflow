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
    static func run(
        seconds: Double, expecting sentinel: String? = nil, viaCopy: Bool = false
    ) -> Int32 {
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

        // What a dictation would do with this window before a single word of it
        // is transcribed: `nowhere` is the pill with no icon in it and a
        // transcript that ends up on the clipboard. Reported here because this
        // is where a verdict that looks wrong gets checked — an app that plainly
        // has a caret in it and reads as `nowhere` is a role this does not know.
        let destination = Destination.at(
            app: front.map {
                Pipeline.App(name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "")
            },
            focus: element
        )
        report("dictation \(destination.described)")

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

        // What the write path will actually be handed. Everything above is raw
        // accessibility; this is the one coordinate space the app edits in, and
        // when the two disagree it is this line that decides what happens.
        if let surface = Surface.read(element: element) {
            report("")
            report("as a surface:")
            report("  kind    \(surface.kind)")
            report("  content \(surface.content.count) chars — \"\(preview(surface.content))\"")
            if let span = surface.span {
                let range = NSRange(span, in: surface.content)
                report("  span    \(range.location)+\(range.length) — \"\(preview(String(surface.content[span])))\"")
            } else {
                report("  span    none")
            }
        } else {
            report("")
            report("as a surface: unreadable — nothing here can be edited in place")
        }

        if let sentinel {
            guard let value, value.contains(sentinel) else {
                report("sentinel  \"\(sentinel)\" NOT in the focused element — wrong window")
                return 2
            }
            report("sentinel  \"\(sentinel)\" found — accessibility and the pane agree")
        }

        report("")
        report("a write here would:")
        describeBranches()

        if viaCopy { reportSelectAllCopy() }
        return 0
    }

    /// Asks the app for its own text with Select All and Copy.
    ///
    /// Opt-in because it borrows the clipboard and leaves a selection on screen.
    /// The question it answers is whether a surface that publishes nothing to
    /// accessibility — Ghostty, iTerm — will still hand over its contents
    /// through the one path every Mac app implements. ⌘-keys are handled by the
    /// application, never forwarded to a pty, so this cannot disturb a shell.
    private static func reportSelectAllCopy() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount

        report("")
        report("via Select All + Copy:")
        postCommandKey(0x00)   // A
        Thread.sleep(forTimeInterval: 0.4)
        postCommandKey(0x08)   // C

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, pasteboard.changeCount == before {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if pasteboard.changeCount == before {
            report("  nothing — the clipboard never changed")
        } else if let text = pasteboard.string(forType: .string) {
            let rows = text.components(separatedBy: "\n")
            report("  \(text.count) chars, \(rows.count) row(s)")
            let borders = rows.filter { SelectionReader.isBorder($0) }.count
            report("  \(borders) row(s) look like a rule the TUI drew")
            if let box = SelectionReader.joinedInputBox(in: text) {
                report("  input box: \(box.count) chars — \"\(preview(box))\"")
            } else {
                report("  input box: none found between the last two rules")
            }
            report("  tail: \"\(preview(text))\"")
        }

        if let saved {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
    }

    private static func postCommandKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Mirrors the branch order in `Surface.replace`. Held in step with it by
    /// hand — when this and the write path disagree, this command is the one
    /// lying, and the harness built on top of it is measuring nothing.
    private static func describeBranches() {
        guard let surface = Surface.read() else {
            report("  nothing — the surface is unreadable, so no branch is reachable")
            return
        }

        switch surface.kind {
        case .editable:
            // Neither of these can be predicted from a read. Setting a range
            // returns .success in surfaces that then ignore it, which is exactly
            // the lie the write path exists to survive, so this says plainly
            // what is unknowable rather than guessing at it.
            report("  1. set the range, write the text into it — unknowable without")
            report("     writing; a native field takes this one")
            report("  2. set the range, confirm what came back, paste over it —")
            report("     unknowable without writing; this is the branch that carries")
            report("     the web, where selecting works and writing does not")
            report("  3. otherwise refused, and the text goes to the clipboard")

        case .screen:
            if (try? ConfigStore.load())?.transcription.rewriteLine != true {
                report("  retyping the input line — refused, rewrite_line is off")
                return
            }
            report("  retyping the input line (Ctrl-A, Ctrl-K, paste) — the only")
            report("  branch here; a terminal takes keystrokes and refuses the rest")
            report("  content is \(surface.content.count) chars of input box, and")
            report("  the clear is checked between presses rather than assumed")
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
