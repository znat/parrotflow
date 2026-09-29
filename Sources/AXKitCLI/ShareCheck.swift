import AXKit
import AppKit
import Foundation

/// `axkit check --share`: a foreground check. The fixture shares a line of
/// text through File > Share > Messages, then the composer that opens is
/// cancelled. Only a Cancel button is ever pressed: nothing is sent.
enum ShareCheck {
    static func run(json: Bool) -> Int32 {
        let state = NSTemporaryDirectory() + "axkit-share-\(ProcessInfo.processInfo.processIdentifier).json"
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("AXKitFixtures")
        let fixture = Process()
        fixture.executableURL = binary
        fixture.arguments = ["120", "--state", state]
        fixture.standardOutput = FileHandle.nullDevice
        guard (try? fixture.run()) != nil else { fail("no fixture") }
        cleanups.append { fixture.terminate() }
        defer { cleanups.removeLast()() }
        let app = App(pid: fixture.processIdentifier)
        guard Check.wait(10, { Check.window(app) != nil }) else { fail("the fixture did not show") }
        let front = App.frontmost
        defer { front?.activate() }
        _ = app.activate()

        var got = "not run"
        var pass = false
        let wasRunning = App.named("com.apple.MobileSMS") != nil
        do {
            try Controls.menu(["File", "Share", "Messages"], in: app)
            guard Check.wait(3, { Check.truth(state)?["share"] as? String == "Messages" }) else {
                throw AXKitError.ax(.failure, "the menu item did not run")
            }
            // Messages opens its own window with a new draft holding the text,
            // "To:" empty (09-29): no composer in the fixture, no Cancel.
            let messages = "com.apple.MobileSMS"
            var draft: Element?
            var launched: App?
            let started = Date()
            // Cold, Messages takes more than 8 s to show its window (09-29).
            _ = Check.wait(25) {
                guard let app = App.named(messages) else { return false }
                launched = app
                let isDraft = { (e: Element) in e.role == kAXTextFieldRole && e.valueText == "Shared by axkit" }
                // Messages focuses the new draft's field.
                if let focused = app.focusedElement, isDraft(focused) { draft = focused; return true }
                draft = app.windows.lazy.compactMap { $0.first(depth: 20, where: isDraft) }.first
                return draft != nil
            }
            guard let draft, let launched else { throw AXKitError.ax(.failure, "no draft in Messages after 25 s") }
            let seconds = Int(Date().timeIntervalSince(started))
            let to = launched.windows.lazy.compactMap {
                $0.first(depth: 20) { $0.role == kAXTextFieldRole && $0.name == "To:" }
            }.first
            try Controls.setText("", on: draft)
            if !wasRunning { launched.running?.terminate() }
            pass = true
            got = "a new draft in Messages after \(seconds) s holding the text, \(to?.valueText?.isEmpty != false ? "To: empty" : "To: filled"); "
                + "cleared\(wasRunning ? "" : ", Messages quit"), nothing sent"
        } catch {
            got = "\(error)"
        }
        let rows = [Check.Row(control: "share", operation: "File > Share > Messages, then the draft cleared",
                              expected: "a draft in Messages, cleared, nothing sent", got: got, pass: pass, tookFocus: false)]
        Check.report(rows, json: json)
        return pass ? 0 : 1
    }

    /// A window with a Cancel button that is not the fixture's own window.
    static func composer(in app: App) -> Dialog? {
        for window in app.windows where window.title != "Controls" {
            let buttons = window.first(budget: 3000) { $0.role == kAXButtonRole && Glob.matches("Cancel", $0.title ?? $0.name ?? "") }
            if buttons != nil { return Dialogs.dialogFor(window) }
        }
        return nil
    }
}
