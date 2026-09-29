import AXKit
import AppKit
import Foundation

/// `axkit check --browser`: tabs, address bar suggestions and history in a
/// throwaway Chrome, which must stay behind the whole time.
enum BrowserCheck {
    static func run(json: Bool) -> Int32 {
        let folder = FileManager.default.currentDirectoryPath + "/Fixtures/browser"
        let page = { (name: String) in URL(fileURLWithPath: "\(folder)/\(name).html").absoluteString }
        let profile = NSTemporaryDirectory() + "axkit-browser-\(ProcessInfo.processInfo.processIdentifier)"
        let started = Date()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-n", "-b", WebCheck.chrome, "--args", "--user-data-dir=\(profile)", "--no-first-run",
                          "--no-default-browser-check", "--force-renderer-accessibility", "--disable-extensions",
                          "--disable-sync", "--lang=en-US", "--window-size=1200,800",
                          page("alpha"), page("bravo"), page("charlie")]
        do { try open.run(); open.waitUntilExit() } catch { fail("could not open Chrome: \(error)") }
        var instance: NSRunningApplication?
        _ = Check.wait(10) {
            instance = NSRunningApplication.runningApplications(withBundleIdentifier: WebCheck.chrome).first {
                ($0.launchDate ?? .distantPast) >= started.addingTimeInterval(-1)
            }
            return instance != nil
        }
        guard let instance else { fail("the throwaway Chrome did not start") }
        cleanups.append {
            instance.terminate()
            _ = Check.wait(5) { instance.isTerminated }
            try? FileManager.default.removeItem(atPath: profile)
        }
        defer { cleanups.removeLast()() }
        let app = App(pid: instance.processIdentifier)
        app.wake()
        let browser = Browser(app)
        guard Check.wait(10, { browser.tabs.count == 3 && browser.tabs.allSatisfy { $0.title.hasPrefix("AXKit") } }) else {
            fail("the three fixture tabs did not show: \(browser.tabs.map(\.title))")
        }

        let front = App.frontmost?.pid
        var rows: [Check.Row] = []
        func step(_ operation: String, expected: String, _ body: () throws -> (String, Bool)) {
            stopIfLocked()
            var (got, pass) = ("", false)
            do { (got, pass) = try body() } catch { got = "\(error)" }
            rows.append(Check.Row(control: "chrome", operation: operation, expected: expected, got: got, pass: pass,
                                  tookFocus: App.frontmost?.pid != front && App.frontmost?.pid == app.pid))
        }
        let tail = { (url: String?) in url?.split(separator: "/").last.map(String.init) ?? "nothing" }

        step("Browser.tabs", expected: "Alpha, Bravo, Charlie; Alpha shown") {
            let tabs = browser.tabs
            let got = tabs.map { $0.title + ($0.isSelected ? " (shown)" : "") }.joined(separator: ", ")
            return (got, tabs.map(\.title) == ["AXKit Alpha page", "AXKit Bravo page", "AXKit Charlie page"]
                    && tabs.first?.isSelected == true)
        }
        step("Browser.show, a tab by a word of its title", expected: "bravo.html in the address bar") {
            guard let tab = browser.tab(matching: "bravo") else { return ("no tab matches bravo", false) }
            try browser.show(tab)
            _ = Check.wait(2) { tail(browser.address()) == "bravo.html" }
            return (tail(browser.address()), tail(browser.address()) == "bravo.html")
        }
        step("Browser.suggestions on a new tab", expected: "Charlie as an open tab, and a search") {
            try browser.newTab()
            let found = try browser.suggestions(for: "Charlie")
            let got = found.map { "\($0.kind.rawValue) \(tail($0.url))" }.joined(separator: ", ")
            return (got, found.contains { $0.kind == .openTab && tail($0.url) == "charlie.html" }
                    && found.contains { $0.kind == .search })
        }
        step("Browser.go, switching to the open tab", expected: "Charlie shown") {
            guard let row = try browser.suggestions(for: "Charlie").first(where: { $0.kind == .openTab }) else {
                return ("no open-tab suggestion", false)
            }
            try browser.go(row, switchTab: true)
            _ = Check.wait(2) { browser.tabs.first(where: \.isSelected)?.title == "AXKit Charlie page" }
            let shown = browser.tabs.first(where: \.isSelected)?.title ?? "none"
            return ("\(shown) shown, \(browser.tabs.count) tabs", shown == "AXKit Charlie page")
        }
        step("Browser.open, a page not visited yet", expected: "delta.html in a new tab") {
            let count = browser.tabs.count
            try browser.open(page("delta"))
            _ = Check.wait(3) { tail(browser.address()) == "delta.html" }
            return ("\(tail(browser.address())), \(browser.tabs.count - count) new tab(s)",
                    tail(browser.address()) == "delta.html" && browser.tabs.count == count + 1)
        }
        step("Browser.history, a visit by a word", expected: "the Bravo visit, the History tab closed after") {
            let count = browser.tabs.count
            let visits = try browser.history(matching: "Bravo")
            _ = Check.wait(2) { browser.tabs.count == count }
            let got = visits.map { "\($0.title) \(tail($0.url))" }.joined(separator: ", ")
            return ("\(got.isEmpty ? "no visits" : got); \(browser.tabs.count - count) tabs left over",
                    visits.count == 1 && tail(visits.first?.url) == "bravo.html" && browser.tabs.count == count)
        }
        step("Browser.close", expected: "the Delta tab gone") {
            guard let tab = browser.tab(matching: "delta") else { return ("no Delta tab", false) }
            try browser.close(tab)
            return (browser.tabs.map(\.title).joined(separator: ", "), browser.tab(matching: "delta") == nil)
        }
        Check.report(rows, json: json)
        return rows.allSatisfy { $0.pass && !$0.tookFocus } ? 0 : 1
    }
}

/// `axkit check --browser --safari`: the same in the user's Safari, which
/// must not be running: it is launched behind, and quit after. Its visits
/// are deleted from the History view at the end, a foreground step:
/// Safari keeps Delete disabled when it is not in front (09-29).
enum SafariCheck {
    static let safari = "com.apple.Safari"

    static func run(json: Bool) -> Int32 {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: safari).isEmpty else {
            fail("Safari is running: quit it first, so the check touches none of its windows")
        }
        let folder = FileManager.default.currentDirectoryPath + "/Fixtures/browser"
        let page = { (name: String) in URL(fileURLWithPath: "\(folder)/\(name).html").absoluteString }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", "Safari", page("alpha"), page("bravo"), page("charlie")]
        do { try open.run(); open.waitUntilExit() } catch { fail("could not open Safari: \(error)") }
        var app: App?
        _ = Check.wait(15) { app = App.named(safari); return app != nil }
        guard let app else { fail("Safari did not start") }
        let browser = Browser(app)
        cleanups.append { forget(app); quit(app) }
        defer { cleanups.removeLast()() }
        guard Check.wait(15, { browser.tabs.filter { $0.title.hasPrefix("AXKit") }.count == 3 }) else {
            fail("the three fixture tabs did not show: \(browser.tabs.map(\.title))")
        }

        let front = App.frontmost?.pid
        var rows: [Check.Row] = []
        func step(_ operation: String, expected: String, _ body: () throws -> (String, Bool)) {
            stopIfLocked()
            var (got, pass) = ("", false)
            do { (got, pass) = try body() } catch { got = "\(error)" }
            rows.append(Check.Row(control: "safari", operation: operation, expected: expected, got: got, pass: pass,
                                  tookFocus: App.frontmost?.pid != front && App.frontmost?.pid == app.pid))
        }
        let tail = { (url: String?) in url?.split(separator: "/").last.map(String.init) ?? "nothing" }

        // Safari may restore a window from its last session: counts are relative.
        let base = browser.tabs.count
        step("Browser.tabs", expected: "Alpha, Bravo, Charlie") {
            let titles = browser.tabs.map(\.title).filter { $0.hasPrefix("AXKit") }
            return (titles.joined(separator: ", "), titles == ["AXKit Alpha page", "AXKit Bravo page", "AXKit Charlie page"])
        }
        step("Browser.show, a tab by a word of its title", expected: "bravo.html shown") {
            guard let tab = browser.tab(matching: "bravo") else { return ("no tab matches bravo", false) }
            try browser.show(tab)
            _ = Check.wait(2) { tail(browser.address()) == "bravo.html" }
            return (tail(browser.address()), tail(browser.address()) == "bravo.html")
        }
        step("Browser.newTab, then Browser.close", expected: "one more tab, then back to three") {
            try browser.newTab()
            let more = browser.tabs.count
            guard let shown = browser.tabs.first(where: \.isSelected) else { return ("no shown tab", false) }
            try browser.close(shown)
            return ("\(more - base) more, then \(browser.tabs.count - base)", more == base + 1 && browser.tabs.count == base)
        }
        step("Browser.open, a page not visited yet", expected: "delta.html in a new tab") {
            try browser.open(page("delta"))
            _ = Check.wait(3) { tail(browser.address()) == "delta.html" }
            return ("\(tail(browser.address())), \(browser.tabs.count - base) new tab(s)",
                    tail(browser.address()) == "delta.html" && browser.tabs.count == base + 1)
        }
        step("Browser.history, a visit by its words", expected: "the Bravo visit, the tab shown before back") {
            let before = browser.address()
            let visits = try browser.history(matching: "AXKit Bravo")
            _ = Check.wait(2) { browser.address() == before }
            let got = visits.map { "\($0.title) \(tail($0.url))" }.joined(separator: ", ")
            return ("\(got.isEmpty ? "no visits" : got); \(tail(browser.address())) shown",
                    visits.contains { tail($0.url) == "bravo.html" } && browser.address() == before)
        }
        step("Browser.close", expected: "the Delta tab gone") {
            guard let tab = browser.tab(matching: "delta") else { return ("no Delta tab", false) }
            try browser.close(tab)
            return (browser.tabs.map(\.title).joined(separator: ", "), browser.tab(matching: "delta") == nil)
        }
        Check.report(rows, json: json)
        return rows.allSatisfy { $0.pass && !$0.tookFocus } ? 0 : 1
    }

    /// Deletes the fixture visits: the History view, today's AXKit rows
    /// selected, Safari in front, the list focused, then Delete.
    static func forget(_ app: App) {
        guard let item = Controls.menuItem(shortcut: "y", in: app) else { return }
        let window = app.windows.first { $0.subrole == kAXStandardWindowSubrole }
        let outline = { window?.first(depth: 16) { $0.role == kAXOutlineRole && !$0.isInWebArea } }
        if outline() == nil { try? item.perform(kAXPressAction) }
        guard Wait.until(app, timeout: 5, { outline() != nil }), let list = outline() else {
            FileHandle.standardError.write("could not open the History view: the AXKit visits stay\n".data(using: .utf8)!)
            return
        }
        let isOurs = { (row: Element) in
            row.first(depth: 6) { $0.role == kAXStaticTextRole || $0.role == kAXTextFieldRole }?.valueText?.hasPrefix("AXKit") == true
        }
        let front = App.frontmost
        FileHandle.standardError.write("Safari comes in front to delete the check's visits\n".data(using: .utf8)!)
        _ = app.activate()
        FileHandle.standardError.write("Safari in front by \(App.lastActivation ?? "nothing")\n".data(using: .utf8)!)
        try? list.set(kAXFocusedAttribute, to: kCFBooleanTrue)
        let ours = list.elements(kAXRowsAttribute).filter(isOurs)
        try? list.set(kAXSelectedRowsAttribute, to: ours.map(\.ref) as CFArray)
        let selected = list.elements(kAXSelectedRowsAttribute)
        // Edit > Delete has no shortcut to find it by. It is enabled a moment
        // after Safari says it is in front (09-29).
        let edit = app.element.element(kAXMenuBarAttribute)?.children.first { $0.title == "Edit" }
        let delete = edit?.first(budget: 60) { $0.role == kAXMenuItemRole && $0.title == "Delete" }
        _ = Check.wait(3) { delete?.isEnabled == true }
        if !selected.isEmpty, selected.allSatisfy(isOurs), let delete {
            try? delete.perform(kAXPressAction)
        } else {
            FileHandle.standardError.write("not deleted: \(ours.count) AXKit rows, \(selected.count) selected, Delete \(delete == nil ? "not found" : "found, enabled \(delete?.isEnabled == true)")\n".data(using: .utf8)!)
        }
        _ = Check.wait(2) { !list.elements(kAXRowsAttribute).contains(where: isOurs) }
        let left = list.elements(kAXRowsAttribute).filter(isOurs).count
        FileHandle.standardError.write("AXKit visits left in Safari's history: \(left)\n".data(using: .utf8)!)
        front?.activate()
    }

    static func quit(_ app: App) {
        for window in app.windows where window.subrole == kAXStandardWindowSubrole {
            try? window.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
        }
        app.running?.terminate()
        _ = Check.wait(5) { app.running?.isTerminated ?? true }
    }
}
