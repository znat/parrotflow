import AXKit
import AppKit
import Foundation

/// `axkit check --system`: the Dock, the menu bar, and moving things between
/// apps. Two fixture windows in the background, one with a Dock badge and a
/// menu bar icon. Copying with ⌘C is a short foreground step.
enum SystemCheck {
    static func run(json: Bool) -> Int32 {
        let state = NSTemporaryDirectory() + "axkit-system-\(ProcessInfo.processInfo.processIdentifier).json"
        guard let a = LayoutCheck.open("Source", ["--badge", "3", "--state", state]),
              let b = LayoutCheck.open("Target") else { fail("the fixture windows did not show") }
        cleanups.append {
            a.process.terminate()
            b.process.terminate()
        }
        defer { cleanups.removeLast()() }
        let appA = App(pid: a.process.processIdentifier)
        var rows: [Check.Row] = []
        func row(_ control: String, _ operation: String, _ expected: String, _ body: () throws -> String) {
            var got: String
            var pass = false
            do { got = try body(); pass = true } catch { got = "\(error)" }
            rows.append(Check.Row(control: control, operation: operation, expected: expected, got: got,
                                  pass: pass, tookFocus: false))
        }
        func field(_ window: Element, _ id: String) throws -> Element {
            guard let hit = window.first(where: { $0.identifier == id }) else { throw AXKitError.ax(.failure, "find \(id)") }
            return hit
        }

        row("Dock", "System.dock: the fixture's badge", "3") {
            var badge: String?
            _ = Check.wait(5) {
                badge = System.dock.first { $0.name == "AXKitFixtures" && $0.badge != nil }?.badge
                return badge != nil
            }
            guard badge == "3" else { throw AXKitError.ax(.failure, "badge \(badge ?? "none")") }
            return "3, and \(System.dock.compactMap(\.badge).count) badge(s) in the Dock"
        }
        row("menu bar", "System.menuExtra: AXK, then Status action", "the fixture reports it") {
            guard let extra = System.menuExtras.first(where: { $0.name == "AXK" && $0.app == "AXKitFixtures" }) else {
                throw AXKitError.ax(.failure, "no AXK among \(System.menuExtras.count) icons")
            }
            try System.menuExtra(extra, choose: "Status action")
            guard Check.wait(2, { Check.truth(state)?["status_menu"] as? String == "chosen" }) else {
                throw AXKitError.ax(.failure, "pressed, but the fixture did not report it")
            }
            return "chosen"
        }
        row("text", "Controls.text from one app, setText in another", "Room from Source") {
            let from = try field(a.element, "room")
            try Controls.setText("Room from Source", on: from)
            guard let text = Controls.text(of: from) else { throw AXKitError.ax(.failure, "nothing read") }
            let to = try field(b.element, "notes")
            try Controls.setText(text, on: to)
            return to.valueText ?? ""
        }
        row("copy", "Controls.copy with ⌘C (in front), clipboard kept", "the field's text, then the clipboard as it was") {
            let before = NSPasteboard.general.string(forType: .string)
            let from = try field(a.element, "notes")
            try Controls.setText("Copied by axkit", on: from)
            try Input.selectAll(from)
            let copied = try Controls.copy(near: from)
            guard copied.string == "Copied by axkit" else {
                throw AXKitError.ax(.failure, "copied \(copied.string ?? "nothing") with \(copied.types)")
            }
            guard NSPasteboard.general.string(forType: .string) == before else {
                throw AXKitError.ax(.failure, "the clipboard was not put back")
            }
            return "\"\(copied.string ?? "")\" (\(copied.types.count) types), then the clipboard as it was"
        }
        row("open with", "App.open a file with TextEdit, in the background", "its window, the front app kept") {
            let front = App.frontmost?.pid
            let file = URL(fileURLWithPath: NSTemporaryDirectory() + "axkit-open-with.txt")
            try "opened with axkit\n".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let wasRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first != nil
            let sentBack = try App.open(file, with: "com.apple.TextEdit")
            var window: Element?
            _ = Check.wait(8) {
                window = App.named("com.apple.TextEdit")?.windows.first { ($0.title ?? "").hasPrefix("axkit-open-with") }
                return window != nil
            }
            guard let window else { throw AXKitError.ax(.failure, "no TextEdit window") }
            defer {
                try? window.first(budget: 50, where: { $0.subrole == kAXCloseButtonSubrole })?.perform(kAXPressAction)
                if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.terminate() }
            }
            guard App.frontmost?.pid == front else { throw AXKitError.ax(.failure, "TextEdit stayed in front") }
            return "window \"\(window.title ?? "")\", " + (sentBack ? "TextEdit came in front and was sent back" : "the front app kept")
        }
        _ = appA
        Check.report(rows, json: json)
        return rows.allSatisfy(\.pass) ? 0 : 1
    }
}
