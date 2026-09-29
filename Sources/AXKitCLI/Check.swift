import AXKit
import AppKit
import Foundation

/// `axkit check`: opens the fixture window behind every other, plays each
/// control operation through accessibility only, and compares what the window
/// reports it received with what was measured on 2026-09-27.
enum Check {
    /// Accents, AZERTY dead keys, emoji with a skin tone, right-to-left and
    /// CJK text: what `type` must pass through untouched.
    static let special = "é à ç ô ü ï ñ ß € £ « » – … ^ ¨ 🙂👍🏽 مرحبا שלום 日本語"

    enum Expect {
        /// The truth key takes this value.
        case becomes(String, Any)
        /// The app ignores the operation: the truth key keeps its value.
        case ignored(String)
        /// The call itself is refused with this error, and nothing changes.
        case refused(String, AXError)
        /// The truth key holds a date with this day, or this hour and minute.
        case becomesDay(String, Date)
        case becomesTime(String, Date)
    }

    struct Case {
        let control: String
        let operation: String
        let expect: Expect
        let run: () throws -> Void
    }

    struct Row: Encodable {
        var control: String
        var operation: String
        var expected: String
        var got: String
        var pass: Bool
        var tookFocus: Bool
    }

    static func run(json: Bool, popups: Bool, keyboard: Bool) -> Int32 {
        let rows = play(popups: popups, keyboard: keyboard)
        report(rows, json: json)
        return rows.allSatisfy { $0.pass && !$0.tookFocus } ? 0 : 1
    }

    /// The matrix `times` times over, each with a fresh fixture: which cases
    /// do not pass every time.
    static func repeated(_ times: Int, popups: Bool, keyboard: Bool) -> Int32 {
        var tally: [String: (pass: Int, runs: Int, focus: Int, last: String)] = [:]
        var order: [String] = []
        let started = Date()
        for round in 1...times {
            for row in play(popups: popups, keyboard: keyboard) where !row.got.hasPrefix("skipped") {
                let key = "\(row.control) · \(row.operation)"
                if tally[key] == nil { order.append(key) }
                var entry = tally[key] ?? (0, 0, 0, "")
                entry.runs += 1
                if row.pass { entry.pass += 1 } else { entry.last = row.got }
                if row.tookFocus { entry.focus += 1 }
                tally[key] = entry
            }
            FileHandle.standardError.write("round \(round)/\(times) done\n".data(using: .utf8)!)
        }
        let unstable = order.filter { tally[$0]!.pass < tally[$0]!.runs || tally[$0]!.focus > 0 }
        for key in unstable {
            let entry = tally[key]!
            print("\(entry.pass)/\(entry.runs)  \(key)" + (entry.focus > 0 ? "  took the focus \(entry.focus)×" : "")
                  + (entry.last.isEmpty ? "" : "  last failure: \(entry.last)"))
        }
        print("-- \(order.count - unstable.count)/\(order.count) cases passed all \(times) rounds, "
              + "\(Int(Date().timeIntervalSince(started))) s")
        return unstable.isEmpty ? 0 : 1
    }

    static func play(popups: Bool, keyboard: Bool) -> [Row] {
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
        cleanups.append { fixture.terminate() }
        defer { cleanups.removeLast()() }

        let app = App(pid: fixture.processIdentifier)
        guard wait(10, { truth(state) != nil && window(app) != nil }), let window = window(app) else {
            fail("the fixture window did not show in 10 s")
        }
        let front = App.frontmost?.pid
        var rows: [Row] = []
        for item in cases(app: app, window: window, popups: popups, keyboard: keyboard) {
            stopIfLocked()
            let before = truth(state) ?? [:]
            var refusal: AXError?
            do { try item.run() } catch AXKitError.ax(let code, _) { refusal = code } catch {
                refusal = .failure
                FileHandle.standardError.write("\(item.control): \(error)\n".data(using: .utf8)!)
            }
            let key: String
            switch item.expect {
            case .becomes(let k, _), .ignored(let k), .refused(let k, _), .becomesDay(let k, _),
                 .becomesTime(let k, _): key = k
            }
            let wanted = expected(item.expect)
            var now = truth(state) ?? [:]
            if let target = goal(item.expect) {
                _ = wait(1.5) { now = truth(state) ?? [:]; return target(now[key]) }
            } else {
                Thread.sleep(forTimeInterval: 0.5)
                now = truth(state) ?? [:]
            }
            let changed = !same(now[key], before[key] as Any)
            let got = refusal.map { "error \($0.rawValue)" + (changed ? ", changed" : "") }
                ?? (changed ? "→ \(show(now[key]))" : "no change")
            if refusal == .apiDisabled {
                rows.append(Row(control: item.control, operation: item.operation, expected: wanted,
                                got: "skipped: this process lacks a permission", pass: true,
                                tookFocus: App.frontmost?.pid != front))
                continue
            }
            let pass: Bool
            switch item.expect {
            case .becomes, .becomesDay, .becomesTime: pass = refusal == nil && goal(item.expect)!(now[key])
            case .ignored: pass = !changed
            case .refused(_, let code): pass = refusal == code && !changed
            }
            rows.append(Row(control: item.control, operation: item.operation, expected: wanted, got: got,
                            pass: pass, tookFocus: App.frontmost?.pid != front))
        }
        return rows
    }

    // MARK: - The cases

    static func cases(app: App, window: Element, popups: Bool, keyboard: Bool) -> [Case] {
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
        func child(_ parent: Element, _ text: String, role: String? = nil) throws -> Element {
            guard let hit = parent.first(where: {
                ($0.name == text || $0.shownText == text) && $0.role != kAXStaticTextRole
                    && (role == nil || $0.role == role)
            })
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
            all.append(Case(control: id, operation: "Controls.setDate", expect: .becomes(id, date)) {
                try Controls.setDate(date, on: try control(id))
            })
        }
        all += [
            // What the API does when misused: the reason the Controls exist.
            Case(control: "fr_date", operation: "set AXValue to a string",
                 expect: .refused("fr_date", .illegalArgument)) {
                try dateArea("fr_date").set(kAXValueAttribute, to: "22/11/2026" as NSString)
            },
            Case(control: "guests", operation: "set AXValue to 7", expect: .ignored("guests")) {
                try control("guests").set(kAXValueAttribute, to: 7 as NSNumber)
            },
            Case(control: "private", operation: "set AXValue to 1", expect: .ignored("private")) {
                try control("private").set(kAXValueAttribute, to: 1 as NSNumber)
            },
            Case(control: "volume", operation: "Controls.setNumber 75", expect: .becomes("volume", 75)) {
                try Controls.setNumber(75, on: try control("volume"))
            },
            Case(control: "volume", operation: "Controls.step +1", expect: .becomes("volume", 80)) {
                try Controls.step(try control("volume"), by: 1)
            },
            Case(control: "guests", operation: "Controls.step +2", expect: .becomes("guests", 5)) {
                try Controls.step(try control("guests"), by: 2)
            },
            Case(control: "private", operation: "Controls.ensure on", expect: .becomes("private", true)) {
                try Controls.ensure(true, try control("private"))
            },
            Case(control: "private", operation: "Controls.ensure on, again", expect: .ignored("private")) {
                try Controls.ensure(true, try control("private"))
            },
            Case(control: "online", operation: "Controls.ensure on", expect: .becomes("online", true)) {
                try Controls.ensure(true, try control("online"))
            },
            Case(control: "show_as", operation: "Controls.ensure on Free", expect: .becomes("show_as", "Free")) {
                try Controls.ensure(true, try control("show_as_free"))
            },
            Case(control: "view", operation: "Controls.press segment Month", expect: .becomes("view", "Month")) {
                try Controls.press(try child(try control("view"), "Month"))
            },
            Case(control: "room", operation: "Controls.setText \"Room C\"", expect: .becomes("room", "Room C")) {
                try Controls.setText("Room C", on: try control("room"))
            },
            Case(control: "tree", operation: "Controls.disclose Fruits",
                 expect: .becomes("tree_expanded", ["Fruits"])) {
                try Controls.disclose(true, try child(try control("tree"), "Fruits", role: kAXRowRole))
            },
            Case(control: "files", operation: "Controls.select rows 0 and 3",
                 expect: .becomes("files_selected", ["alpha.txt", "delta.csv"])) {
                try Controls.select(rows: [0, 3], in: try control("files"))
            },
            Case(control: "sheet", operation: "Controls.press Open sheet", expect: .becomes("sheet", "open")) {
                try Controls.press(try control("open_sheet"))
            },
            Case(control: "sheet", operation: "Controls.press its Cancel", expect: .becomes("sheet", "cancel")) {
                guard let cancel = app.windows.lazy.compactMap({ $0.first { $0.identifier == "sheet_cancel" } }).first
                else { throw AXKitError.ax(.failure, "find sheet_cancel") }
                try Controls.press(cancel)
            },
            Case(control: "menu", operation: "Controls.menu File > Export > PDF…", expect: .becomes("export_pdf", 1)) {
                try Controls.menu(["File", "Export", "PDF…"], in: app)
            },
        ]
        // Windows and apps, read back through accessibility: no keys.
        all += [
            Case(control: "window", operation: "move by 20 points, and back", expect: .ignored("volume")) {
                guard let start = window.frame else { throw AXKitError.ax(.failure, "no frame") }
                try window.move(to: CGPoint(x: start.minX + 20, y: start.minY))
                guard Check.wait(1, { window.frame?.minX == start.minX + 20 }) else {
                    throw AXKitError.ax(.failure, "the window is at \(window.frame.map { "\($0.minX)" } ?? "?")")
                }
                try window.move(to: start.origin)
            },
            Case(control: "window", operation: "resize by 40 points, and back", expect: .ignored("volume")) {
                guard let start = window.frame else { throw AXKitError.ax(.failure, "no frame") }
                try window.resize(to: CGSize(width: start.width + 40, height: start.height))
                guard Check.wait(1, { window.frame?.width == start.width + 40 }) else {
                    throw AXKitError.ax(.failure, "the window is \(window.frame.map { "\($0.width)" } ?? "?") wide")
                }
                try window.resize(to: start.size)
            },
            Case(control: "window", operation: "App.raise, in the background", expect: .ignored("volume")) {
                try app.raise(window)
            },
            Case(control: "window", operation: "Capture.image while it is behind", expect: .ignored("volume")) {
                guard Capture.isAllowed else { throw AXKitError.ax(.apiDisabled, "no Screen Recording permission here") }
                let image = try Capture.image(of: window, in: app)
                guard let frame = window.frame, image.width >= Int(frame.width) else {
                    throw AXKitError.ax(.failure, "the image is \(image.width)×\(image.height)")
                }
            },
            // On a private pasteboard, so the user's is never touched.
            Case(control: "clipboard", operation: "save, replace, restore: rich items", expect: .ignored("volume")) {
                let board = NSPasteboard(name: NSPasteboard.Name("axkit-check-\(ProcessInfo.processInfo.processIdentifier)"))
                defer { board.releaseGlobally() }
                board.clearContents()
                let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                    NSColor.systemPurple.setFill(); rect.fill(); return true }
                let rich = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
                let text = NSPasteboardItem()
                text.setString("plain", forType: .string)
                text.setData(try rich.data(from: NSRange(location: 0, length: 4),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
                             forType: .rtf)
                let picture = NSPasteboardItem()
                picture.setData(image.tiffRepresentation!, forType: .tiff)
                board.writeObjects([text, picture, URL(fileURLWithPath: "/tmp/axkit.txt") as NSURL])
                func snapshot() -> [[String: Data]] {
                    (board.pasteboardItems ?? []).map { item in
                        Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } })
                    }
                }
                let before = snapshot()
                let saved = Clipboard.save(board)
                Clipboard.put(text: "temporary", on: board)
                Clipboard.restore(saved, to: board)
                let after = snapshot()
                guard before == after else {
                    throw AXKitError.ax(.failure, "\(before.count) items with \(before.map(\.count)) types became \(after.count) with \(after.map(\.count))")
                }
            },
            Case(control: "keyboard", operation: "the layout has a key for v", expect: .ignored("volume")) {
                guard Input.keyCode(for: "v") != nil else { throw AXKitError.ax(.failure, "no key for v") }
            },
            Case(control: "notes", operation: "Controls.insert text, no pasteboard",
                 expect: .becomes("notes", "Inserted by axkit")) {
                let before = NSPasteboard.general.changeCount
                try Controls.insert("Inserted by axkit", into: try control("notes"))
                guard NSPasteboard.general.changeCount == before else {
                    throw AXKitError.ax(.failure, "the pasteboard was touched")
                }
            },
        ]
        if keyboard {
            let route = Input.Route.process(app.pid)
            let later = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: paris,
                                       year: 2026, month: 12, day: 3, hour: 16, minute: 41)
            let typed = later.date!
            all += [
                Case(control: "fr_date", operation: "Controls.typeDate dmy", expect: .becomesDay("fr_date", typed)) {
                    try Controls.typeDate(typed, on: try control("fr_date"), order: .dmy, route: route)
                },
                Case(control: "en_date", operation: "Controls.typeDate mdy", expect: .becomesDay("en_date", typed)) {
                    try Controls.typeDate(typed, on: try control("en_date"), order: .mdy, route: route)
                },
                Case(control: "fr_time", operation: "Controls.typeDate time 24 h",
                     expect: .becomesTime("fr_time", typed)) {
                    try Controls.typeDate(typed, on: try control("fr_time"), time: true, route: route)
                },
                Case(control: "en_time", operation: "Controls.typeDate time 12 h",
                     expect: .becomesTime("en_time", typed)) {
                    try Controls.typeDate(typed, on: try control("en_time"), time: true, clock24: false,
                                          route: route)
                },
                Case(control: "file_zone", operation: "Controls.paste a file (in front)",
                     expect: .becomes("pasted_files", ["axkit-attach.txt"])) {
                    let file = URL(fileURLWithPath: NSTemporaryDirectory() + "axkit-attach.txt")
                    try "attached by axkit\n".write(to: file, atomically: true, encoding: .utf8)
                    let zone = try window.first(where: { $0.identifier == "file_zone" })
                        ?? { throw AXKitError.ax(.failure, "find file_zone") }()
                    try Controls.paste(files: [file], into: zone)
                },
                Case(control: "notes", operation: "type accents, dead keys, emoji, RTL, CJK",
                     expect: .becomes("notes", Check.special)) {
                    let notes = try control("notes")
                    guard Input.prepare(notes) else { throw AXKitError.ax(.cannotComplete, "focus notes") }
                    try Input.selectAll(notes)
                    try Input.type(Check.special, to: route)
                },
                Case(control: "room", operation: "select all, type, Return", expect: .becomes("room", "Room D")) {
                    let room = try control("room")
                    guard Input.prepare(room) else { throw AXKitError.ax(.cannotComplete, "focus room") }
                    try Input.selectAll(room)
                    try Input.type("Room D", to: route)
                    try Input.press(.return, to: route)
                },
            ]
        }
        if popups {
            all.append(Case(control: "reminder", operation: "Controls.choose 5 minutes",
                            expect: .becomes("reminder", "5 minutes")) {
                try Controls.choose("5 minutes", in: try control("reminder"))
            })
        }
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

    static func goal(_ expect: Expect) -> ((Any?) -> Bool)? {
        func parts(_ value: Any?, _ wanted: Set<Calendar.Component>) -> DateComponents? {
            guard let text = value as? String, let date = ISO8601DateFormatter().date(from: text) else { return nil }
            return Calendar.current.dateComponents(wanted, from: date)
        }
        switch expect {
        case .becomes(_, let target): return { same($0, target) }
        case .becomesDay(_, let date):
            return { parts($0, [.year, .month, .day]) == Calendar.current.dateComponents([.year, .month, .day], from: date) }
        case .becomesTime(_, let date):
            return { parts($0, [.hour, .minute]) == Calendar.current.dateComponents([.hour, .minute], from: date) }
        case .ignored, .refused: return nil
        }
    }

    static func show(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let list = value as? [Any] { return "[" + list.map { "\($0)" }.joined(separator: ", ") + "]" }
        return "\(value)"
    }

    static func expected(_ expect: Expect) -> String {
        switch expect {
        case .becomes(_, let value): return "→ \(value is Date ? "the date" : show(value))"
        case .becomesDay: return "→ the day"
        case .becomesTime: return "→ the time"
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
            let mark = row.got.hasPrefix("skipped") ? "skip" : row.pass ? "ok  " : "FAIL"
            let focus = row.tookFocus ? "  (took the focus)" : ""
            print("\(mark) \(row.control.padding(toLength: 18, withPad: " ", startingAt: 0)) "
                  + "\(row.operation.padding(toLength: 36, withPad: " ", startingAt: 0)) "
                  + "expected \(row.expected), got \(row.got)\(focus)")
        }
        let skipped = rows.filter { $0.got.hasPrefix("skipped") }.count
        print("-- \(rows.filter(\.pass).count - skipped)/\(rows.count - skipped) as measured"
              + (skipped > 0 ? ", \(skipped) skipped" : "")
              + (rows.contains(where: \.tookFocus) ? ", the focus moved" : ", the focus never moved"))
    }
}
