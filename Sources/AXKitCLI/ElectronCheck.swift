import AXKit
import AppKit
import Foundation

/// `axkit check --electron`: starts Fixtures/electron-app, a window that
/// copies the patterns of Teams (a menu behind "Create a new event.",
/// attendees announced but not in the tree, date and time behind a summary
/// button) and Slack (menu-item suggestions, a contenteditable composer). The
/// window shows without taking the focus. Truth as in the web check.
enum ElectronCheck {
    static func run(folder: String, json: Bool, only: String?) -> Int32 {
        let binary = folder + "/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            fail("no Electron at \(binary): npm install in \(folder)")
        }
        let electron = Process()
        electron.executableURL = URL(fileURLWithPath: binary)
        electron.arguments = [folder]
        electron.standardOutput = FileHandle.nullDevice
        electron.standardError = FileHandle.nullDevice
        do { try electron.run() } catch { fail("could not start Electron: \(error)") }
        defer { electron.terminate() }
        let app = App(pid: electron.processIdentifier)

        guard Check.wait(15, { app.windows.contains { Glob.matches("Web controls*", $0.title ?? "") } }),
              let window = app.windows.first(where: { Glob.matches("Web controls*", $0.title ?? "") }) else {
            fail("the Electron window did not show in 15 s")
        }
        // Electron builds its tree only when asked: this is what wake is for.
        let asleep = Walk.run(from: window, options: WalkOptions(budget: 3000)).nodes.count
        let readAsleep = WebCheck.truth(app) != nil
        app.wake()
        let readAwake = Check.wait(5) { WebCheck.truth(app)?["ready"] as? Bool == true }
        let awake = Walk.run(from: window, options: WalkOptions(budget: 3000)).nodes.count
        var rows = [Check.Row(control: "window", operation: "wake", expected: "the page unreadable, then readable",
                              got: "\(readAsleep ? "readable" : "unreadable") (\(asleep) elements), then "
                                  + "\(readAwake ? "readable" : "unreadable") (\(awake))",
                              pass: !readAsleep && readAwake, tookFocus: false)]
        rows += WebCheck.play(app, cases(app).filter { only == nil || $0.key == only })
        Check.report(rows, json: json)
        return rows.allSatisfy { $0.pass && !$0.tookFocus } ? 0 : 1
    }

    static func cases(_ app: App) -> [WebCheck.Case] {
        let byDom = { (id: String) in try WebCheck.byDom(app, id) }
        let route = Input.Route.process(app.pid)
        // A menu shows in the tree a moment after it opens.
        func item(_ name: String) throws -> Element {
            var hit: Element?
            _ = Check.wait(2) {
                hit = app.windows.first(where: { Glob.matches("Web controls*", $0.title ?? "") })?
                    .first(where: { $0.role == kAXMenuItemRole && $0.shownText == name })
                return hit != nil
            }
            guard let hit else { throw AXKitError.ax(.failure, "no menu item \"\(name)\"") }
            return hit
        }
        func announced(_ pattern: String) throws {
            guard Check.wait(2, { Glob.matches(pattern, (try? byDom("announce"))?.shownText ?? "") }) else {
                throw AXKitError.notApplied("announce \"\(pattern)\", got \"\((try? byDom("announce"))?.shownText ?? "")\"")
            }
        }
        return [
            WebCheck.Case(key: "form", operation: "press \"Create a new event.\" menu, then Event", becomes: "open") {
                try Controls.press(try byDom("create_menu"))
                try Controls.press(try item("Event"))
            },
            WebCheck.Case(key: "title", operation: "Controls.setText Add title", becomes: "Weekly sync") {
                try Controls.setText("Weekly sync", on: try byDom("title"))
            },
            WebCheck.Case(key: "attendees", operation: "type Alice, read the announced row, Return",
                          becomes: ["alice.martin@example.com"]) {
                let field = try byDom("attendees")
                guard Input.prepare(field) else { throw AXKitError.ax(.cannotComplete, "focus attendees") }
                try Input.type("Alice", to: route)
                try announced("Alice Martin - alice.martin@example.com 1 of 2")
                try Input.press(.return, to: route)
            },
            WebCheck.Case(key: "times", operation: "press the summary button", becomes: "open") {
                try Controls.press(try byDom("summary"))
            },
            WebCheck.Case(key: "start_date", operation: "Controls.setText Start date", becomes: "03/12/26") {
                try Controls.setText("03/12/26", on: try byDom("start_date"))
            },
            WebCheck.Case(key: "start_time", operation: "select all, type 16:30, Return", becomes: "16:30") {
                let field = try byDom("start_time")
                guard Input.prepare(field) else { throw AXKitError.ax(.cannotComplete, "focus start_time") }
                try Input.selectAll(field)
                try Input.type("16:30", to: route)
                try Input.press(.return, to: route)
            },
            WebCheck.Case(key: "end_time", operation: "follows the start time", becomes: "17:00") {},
            WebCheck.Case(key: "view", operation: "press the Chat tab", becomes: "Chat") {
                try Controls.press(try byDom("tab_chat"))
            },
            WebCheck.Case(key: "compose", operation: "press New message", becomes: "open") {
                try Controls.press(try byDom("new_message"))
            },
            WebCheck.Case(key: "recipients", operation: "type Bruno in To:, press the row", becomes: ["Bruno Costa"]) {
                let to = try byDom("to")
                guard Input.prepare(to) else { throw AXKitError.ax(.cannotComplete, "focus To:") }
                try Input.type("Bruno", to: route)
                try Controls.press(try item("Bruno Costa"))
            },
            WebCheck.Case(key: "message", operation: "Controls.setText the composer (typed)", becomes: "Hello team") {
                try Controls.setText("Hello team", on: try byDom("message"))
            },
        ]
    }
}
