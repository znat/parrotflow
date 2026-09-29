import AXKit
import AppKit
import Foundation

/// `axkit check --apps`: opens Calculator and a text file in TextEdit
/// without bringing either in front, checks that the front app stayed, and
/// quits what it opened. An app that was already running is left alone.
enum AppsCheck {
    static func run(json: Bool) -> Int32 {
        var rows: [Check.Row] = []
        let front = App.frontmost

        func running(_ bundle: String) -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        }

        let calculator = "com.apple.calculator"
        let calcWasRunning = running(calculator) != nil
        var got = "no change"
        var pass = false
        do {
            let app = try App.launch(bundle: calculator, background: true)
            _ = Check.wait(5) { !app.windows.isEmpty }
            let stayed = App.frontmost?.pid == front?.pid
            pass = running(calculator) != nil && stayed
            got = "running with \(app.windows.count) window(s), \(stayed ? "the front app stayed" : "it came in front")"
        } catch {
            got = "\(error)"
        }
        rows.append(Check.Row(control: "Calculator", operation: "App.launch in the background",
                              expected: "running, not in front", got: got, pass: pass, tookFocus: false))
        if !calcWasRunning { running(calculator)?.terminate() }

        let textEdit = "com.apple.TextEdit"
        let editWasRunning = running(textEdit) != nil
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "axkit-open.txt")
        try? "opened by axkit\n".write(to: file, atomically: true, encoding: .utf8)
        App.open(file, background: true)
        var window: Element?
        _ = Check.wait(8) {
            window = running(textEdit).flatMap { App(pid: $0.processIdentifier).windows.first { ($0.title ?? "").hasPrefix("axkit-open") } }
            return window != nil
        }
        let stayed = App.frontmost?.pid == front?.pid
        rows.append(Check.Row(control: "TextEdit", operation: "App.open a file in the background",
                              expected: "its window, not in front",
                              got: window == nil ? "no window" : "window \"\(window?.title ?? "")\", \(stayed ? "the front app stayed" : "it came in front")",
                              pass: window != nil && stayed, tookFocus: false))
        if let close = window?.first(budget: 50, where: { $0.subrole == kAXCloseButtonSubrole }) {
            try? close.perform(kAXPressAction)
        }
        if !editWasRunning { running(textEdit)?.terminate() }
        try? FileManager.default.removeItem(at: file)

        Check.report(rows, json: json)
        return rows.allSatisfy(\.pass) ? 0 : 1
    }
}
