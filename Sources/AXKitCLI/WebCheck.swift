import AXKit
import AppKit
import Foundation

/// `axkit check --web`: opens Fixtures/web-controls in a throwaway Chrome
/// profile, without bringing it in front, and plays the Controls on the
/// page's controls. The truth is what each control's framework reports into
/// the page's `<pre id="truth">`, read back through accessibility.
enum WebCheck {
    static let chrome = "com.google.Chrome"

    static func run(page: String, json: Bool, only: String?, keys: Bool) -> Int32 {
        guard FileManager.default.fileExists(atPath: page) else { fail("no page at \(page)") }
        let profile = NSTemporaryDirectory() + "axkit-web-\(ProcessInfo.processInfo.processIdentifier)"
        let started = Date()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-n", "-b", chrome, "--args", "--user-data-dir=\(profile)", "--no-first-run",
                          "--no-default-browser-check", "--force-renderer-accessibility", "--disable-extensions",
                          "--disable-sync", "--lang=en-US", "--window-size=1400,1000",
                          URL(fileURLWithPath: page).absoluteString]
        do { try open.run(); open.waitUntilExit() } catch { fail("could not open Chrome: \(error)") }

        var instance: NSRunningApplication?
        _ = Check.wait(10) {
            instance = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == chrome && ($0.launchDate ?? .distantPast) >= started.addingTimeInterval(-1)
            }
            return instance != nil
        }
        guard let instance else { fail("the throwaway Chrome did not start") }
        defer {
            instance.terminate()
            _ = Check.wait(5) { instance.isTerminated }
            try? FileManager.default.removeItem(atPath: profile)
        }
        let app = App(pid: instance.processIdentifier)
        app.wake()
        // The libraries load from a CDN: wait for all three to report.
        guard Check.wait(30, { (truth(app)?["libs"] as? [String: Any])?.count ?? 0 >= 3 }) else {
            fail("the page did not finish loading in 30 s: \(truth(app).map { "\($0["libs"] ?? "")" } ?? "no truth")")
        }
        let rows = play(app, cases(app, keys: keys).filter { only == nil || $0.key == only })
        Check.report(rows, json: json)
        return rows.allSatisfy { $0.pass && !$0.tookFocus } ? 0 : 1
    }

    /// Plays each case and reads the page's truth before and after it.
    static func play(_ app: App, _ cases: [Case]) -> [Check.Row] {
        let front = App.frontmost?.pid
        var rows: [Check.Row] = []
        for item in cases {
            let before = truth(app) ?? [:]
            var declined: String?
            do { try item.run() } catch { declined = "\(error)" }
            var now = truth(app) ?? [:]
            if let target = item.becomes {
                _ = Check.wait(2) { now = truth(app) ?? [:]; return Check.same(now[item.key], target) }
            } else {
                Thread.sleep(forTimeInterval: 0.5)
                now = truth(app) ?? [:]
            }
            let changed = !Check.same(now[item.key], before[item.key] as Any)
            let pass = item.becomes.map { declined == nil && Check.same(now[item.key], $0) } ?? (declined != nil && !changed)
            let got = (declined.map { "declined: \($0)" + (changed ? "; the page got \(Check.show(now[item.key]))" : "") })
                ?? (changed ? "→ \(Check.show(now[item.key]))" : "no change")
            rows.append(Check.Row(control: item.key, operation: item.operation,
                                  expected: item.becomes.map { "→ \(Check.show($0))" } ?? "declined, no change",
                                  got: got, pass: pass, tookFocus: App.frontmost?.pid != front))
        }
        return rows
    }

    struct Case {
        let key: String
        let operation: String
        /// nil: the operation must decline and leave the page as it was.
        let becomes: Any?
        let run: () throws -> Void
    }

    static func cases(_ app: App, keys: Bool) -> [Case] {
        let byDom = { (id: String) in try WebCheck.byDom(app, id) }
        let parts = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 12, day: 3)
        return [
            Case(key: "n_text", operation: "Controls.setText (input)", becomes: "Weekly sync") {
                try Controls.setText("Weekly sync", on: try byDom("n_text"))
            },
            Case(key: "r_text", operation: "Controls.setText (React input)", becomes: "Weekly sync") {
                try Controls.setText("Weekly sync", on: try byDom("r_text"))
            },
            Case(key: "n_textarea", operation: "Controls.setText (textarea, typed)", becomes: "Second draft") {
                try Controls.setText("Second draft", on: try byDom("n_textarea"))
            },
            Case(key: "n_editable", operation: "Controls.setText (contenteditable, typed)", becomes: "Hello team") {
                try Controls.setText("Hello team", on: try byDom("n_editable"))
            },
            Case(key: "n_checkbox", operation: "Controls.ensure on", becomes: true) {
                try Controls.ensure(true, try byDom("n_checkbox"))
            },
            Case(key: "r_checkbox", operation: "Controls.ensure on (React)", becomes: true) {
                try Controls.ensure(true, try byDom("r_checkbox"))
            },
            Case(key: "a_switch", operation: "Controls.ensure on (ARIA switch)", becomes: true) {
                try Controls.ensure(true, try byDom("a_switch"))
            },
            Case(key: "m_checkbox", operation: "Controls.ensure on (Material, state hidden)", becomes: nil) {
                try Controls.ensure(true, try byDom("m_checkbox"))
            },
            Case(key: "n_range", operation: "Controls.setNumber 60 (stepped)", becomes: "60") {
                try Controls.setNumber(60, on: try byDom("n_range"))
            },
            Case(key: "n_date", operation: "Controls.setDate (its parts)", becomes: "2026-12-03") {
                try Controls.setDate(parts.date!, on: try byDom("n_date"), keys: keys)
            },
            Case(key: "n_select", operation: "Controls.choose 1 hour (typed)", becomes: "1 hour") {
                try Controls.choose("1 hour", in: try byDom("n_select"))
            },
            Case(key: "a_tabs", operation: "Controls.press tab Week", becomes: "Week") {
                try Controls.press(try byDom("a_tab_week"))
            },
            Case(key: "a_disclosure", operation: "Controls.press disclosure", becomes: true) {
                try Controls.press(try byDom("a_disclosure"))
            },
        ]
    }

    static func byDom(_ app: App, _ id: String) throws -> Element {
        guard let window = app.windows.first(where: { Glob.matches("Web controls*", $0.title ?? "") }),
              let hit = Walk.find(in: window, dom: id, options: WalkOptions(budget: 20000)).first?.0
        else { throw AXKitError.ax(.failure, "find #\(id)") }
        return hit
    }

    /// The page's `<pre id="truth">`, parsed.
    static func truth(_ app: App) -> [String: Any]? {
        guard let window = app.windows.first(where: { Glob.matches("Web controls*", $0.title ?? "") }),
              let pre = Walk.find(in: window, dom: "truth", options: WalkOptions(budget: 20000)).first?.0,
              case let lines = Walk.find(in: pre, role: kAXStaticTextRole, options: WalkOptions(budget: 500, valueLimit: 100_000))
                  .compactMap(\.1.value),
              let data = (lines.isEmpty ? pre.valueText ?? "" : lines.joined(separator: "\n")).data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
