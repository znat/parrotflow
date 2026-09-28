import AXKit
import AppKit
import Foundation

/// `axkit check`: opens the fixture window behind every other, plays each
/// control operation through accessibility only, and compares what the window
/// reports it received with what was measured on 2026-09-27.
enum Check {
    enum Expect {
        /// The truth key takes this value.
        case becomes(String, Any)
        /// The app ignores the operation: the truth key keeps its value.
        case ignored(String)
        /// The call itself is refused with this error, and nothing changes.
        case refused(String, AXError)
    }

    struct Case {
        let control: String
        let operation: String
        let expect: Expect
        let run: () throws -> Void
    }

    struct Row: Encodable {
        let control: String
        let operation: String
        let expected: String
        let got: String
        let pass: Bool
        let tookFocus: Bool
    }

    static func run(json: Bool) -> Int32 {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("AXKitFixtures").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            fail("no fixture app at \(binary): swift build --product AXKitFixtures")
        }
        let state = NSTemporaryDirectory() + "axkit-check-\(ProcessInfo.processInfo.processIdentifier).json"
        try? FileManager.default.removeItem(atPath: state)
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: binary)
        fixture.arguments = ["300", "--state", state, "--background"]
        fixture.standardOutput = FileHandle.nullDevice
        do { try fixture.run() } catch { fail("could not start the fixture app: \(error)") }
        defer { fixture.terminate() }

        let app = App(pid: fixture.processIdentifier)
        guard wait(10, { truth(state) != nil && window(app) != nil }), let window = window(app) else {
            fail("the fixture window did not show in 10 s")
        }
        let front = App.frontmost?.pid
        var rows: [Row] = []
        for item in cases(app: app, window: window) {
            let before = truth(state) ?? [:]
            var refusal: AXError?
            do { try item.run() } catch AXKitError.ax(let code, _) { refusal = code } catch { refusal = .failure }
            let key: String
            switch item.expect {
            case .becomes(let k, _), .ignored(let k), .refused(let k, _): key = k
            }
            let wanted = expected(item.expect)
            var now = truth(state) ?? [:]
            if case .becomes(_, let target) = item.expect {
                _ = wait(1.5) { now = truth(state) ?? [:]; return same(now[key], target) }
            } else {
                Thread.sleep(forTimeInterval: 0.5)
                now = truth(state) ?? [:]
            }
            let changed = !same(now[key], before[key] as Any)
            let got = refusal.map { "error \($0.rawValue)" + (changed ? ", changed" : "") }
                ?? (changed ? "→ \(show(now[key]))" : "no change")
            let pass: Bool
            switch item.expect {
            case .becomes(_, let target): pass = refusal == nil && same(now[key], target)
            case .ignored: pass = !changed
            case .refused(_, let code): pass = refusal == code && !changed
            }
            rows.append(Row(control: item.control, operation: item.operation, expected: wanted, got: got,
                            pass: pass, tookFocus: App.frontmost?.pid != front))
        }
        report(rows, json: json)
        return rows.allSatisfy { $0.pass && !$0.tookFocus } ? 0 : 1
    }

    // MARK: - The cases

    static func cases(app: App, window: Element) -> [Case] {
        func control(_ id: String) throws -> Element {
            guard let hit = window.first(where: { $0.identifier == id }) else {
                throw AXKitError.ax(.failure, "find \(id)")
            }
            let wrappers: Set<String> = [kAXGroupRole, kAXUnknownRole, kAXScrollAreaRole]
            return wrappers.contains(hit.role ?? "") ? hit.children.first ?? hit : hit
        }
        func dateArea(_ id: String) throws -> Element {
            let found = try control(id)
            if found.role == "AXDateTimeArea" { return found }
            return found.first { $0.role == "AXDateTimeArea" } ?? found
        }
        func child(_ parent: Element, _ text: String) throws -> Element {
            guard let hit = parent.first(where: { ($0.name == text || $0.shownText == text) && $0.role != kAXStaticTextRole })
            else { throw AXKitError.ax(.failure, "find \"\(text)\"") }
            return hit
        }
        let paris = TimeZone(identifier: "Europe/Paris")!
        let parts = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: paris,
                                   year: 2026, month: 11, day: 20, hour: 9, minute: 5)
        let date = parts.date!

        var all: [Case] = []
        for id in ["fr_date", "fr_time", "fr_datetime", "fr_date_field", "fr_time_field",
                   "en_date", "en_time", "en_datetime_field"] {
            all.append(Case(control: id, operation: "set AXValue to a Date", expect: .becomes(id, date)) {
                try dateArea(id).set(kAXValueAttribute, to: date as NSDate)
            })
        }
        all.append(Case(control: "fr_date", operation: "set AXValue to a string",
                        expect: .refused("fr_date", .illegalArgument)) {
            try dateArea("fr_date").set(kAXValueAttribute, to: "22/11/2026" as NSString)
        })
        all += [
            Case(control: "volume", operation: "set AXValue to 75", expect: .becomes("volume", 75)) {
                try control("volume").set(kAXValueAttribute, to: 75 as NSNumber)
            },
            Case(control: "volume", operation: "AXIncrement", expect: .becomes("volume", 80)) {
                try control("volume").perform(kAXIncrementAction)
            },
            Case(control: "guests", operation: "AXIncrement", expect: .becomes("guests", 4)) {
                try control("guests").perform(kAXIncrementAction)
            },
            Case(control: "guests", operation: "set AXValue to 7", expect: .ignored("guests")) {
                try control("guests").set(kAXValueAttribute, to: 7 as NSNumber)
            },
            Case(control: "private", operation: "AXPress", expect: .becomes("private", true)) {
                try control("private").perform(kAXPressAction)
            },
            Case(control: "private", operation: "set AXValue to 0", expect: .ignored("private")) {
                try control("private").set(kAXValueAttribute, to: 0 as NSNumber)
            },
            Case(control: "online", operation: "AXPress", expect: .becomes("online", true)) {
                try control("online").perform(kAXPressAction)
            },
            Case(control: "show_as", operation: "AXPress on Free", expect: .becomes("show_as", "Free")) {
                try control("show_as_free").perform(kAXPressAction)
            },
            Case(control: "view", operation: "AXPress on segment Month", expect: .becomes("view", "Month")) {
                try child(try control("view"), "Month").perform(kAXPressAction)
            },
            Case(control: "room", operation: "set AXValue to \"Room C\"", expect: .becomes("room", "Room C")) {
                try control("room").set(kAXValueAttribute, to: "Room C" as NSString)
            },
            Case(control: "tree", operation: "set AXDisclosing on Fruits",
                 expect: .becomes("tree_expanded", ["Fruits"])) {
                let row = try control("tree").first { $0.role == kAXRowRole && $0.shownText == "Fruits" }
                try (row ?? window).set(kAXDisclosingAttribute, to: kCFBooleanTrue)
            },
            Case(control: "tree", operation: "set AXSelected on Pear", expect: .becomes("tree_selected", "Pear")) {
                let row = try control("tree").first { $0.role == kAXRowRole && $0.shownText == "Pear" }
                try (row ?? window).set(kAXSelectedAttribute, to: kCFBooleanTrue)
            },
            Case(control: "files", operation: "set AXSelectedRows to rows 1 and 4",
                 expect: .becomes("files_selected", ["alpha.txt", "delta.csv"])) {
                let table = try control("files")
                let rows = table.elements(kAXRowsAttribute)
                guard rows.count >= 4 else { throw AXKitError.ax(.failure, "rows") }
                try table.set(kAXSelectedRowsAttribute, to: [rows[0].ref, rows[3].ref] as CFArray)
            },
            Case(control: "sheet", operation: "AXPress Open sheet", expect: .becomes("sheet", "open")) {
                try control("open_sheet").perform(kAXPressAction)
            },
            Case(control: "sheet", operation: "AXPress its Cancel", expect: .becomes("sheet", "cancel")) {
                guard let cancel = app.windows.lazy.compactMap({ $0.first { $0.identifier == "sheet_cancel" } }).first
                else { throw AXKitError.ax(.failure, "find sheet_cancel") }
                try cancel.perform(kAXPressAction)
            },
            Case(control: "menu", operation: "AXPress File > Export > PDF…", expect: .becomes("export_pdf", 1)) {
                guard let bar = app.element.element(kAXMenuBarAttribute),
                      let pdf = bar.first(where: { $0.role == kAXMenuItemRole && $0.title == "PDF…" })
                else { throw AXKitError.ax(.failure, "find PDF…") }
                try pdf.perform(kAXPressAction)
            },
        ]
        return all
    }

    // MARK: -

    static func window(_ app: App) -> Element? {
        app.windows.first { $0.title == "Controls" }
    }

    static func truth(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func wait(_ seconds: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return done()
    }

    static func same(_ value: Any?, _ target: Any) -> Bool {
        if let date = target as? Date, let text = value as? String,
           let got = ISO8601DateFormatter().date(from: text) {
            return abs(got.timeIntervalSince(date)) < 1
        }
        if let number = target as? Int { return (value as? NSNumber)?.doubleValue == Double(number) }
        if let flag = target as? Bool { return (value as? Bool) == flag }
        if let list = target as? [String] { return (value as? [String]) == list }
        if let text = target as? String { return (value as? String) == text }
        return false
    }

    static func show(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let list = value as? [Any] { return "[" + list.map { "\($0)" }.joined(separator: ", ") + "]" }
        return "\(value)"
    }

    static func expected(_ expect: Expect) -> String {
        switch expect {
        case .becomes(_, let value): return "→ \(value is Date ? "the date" : show(value))"
        case .ignored: return "no change"
        case .refused(_, let code): return "error \(code.rawValue)"
        }
    }

    static func report(_ rows: [Row], json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try! encoder.encode(rows), encoding: .utf8)!)
            return
        }
        for row in rows {
            let mark = row.pass ? "ok  " : "FAIL"
            let focus = row.tookFocus ? "  (took the focus)" : ""
            print("\(mark) \(row.control.padding(toLength: 18, withPad: " ", startingAt: 0)) "
                  + "\(row.operation.padding(toLength: 36, withPad: " ", startingAt: 0)) "
                  + "expected \(row.expected), got \(row.got)\(focus)")
        }
        print("-- \(rows.filter(\.pass).count)/\(rows.count) as measured"
              + (rows.contains(where: \.tookFocus) ? ", the focus moved" : ", the focus never moved"))
    }
}
