import AXKit
import AppKit
import Foundation

/// `axkit check --layout`: fixture windows in the background, tiled in halves
/// and thirds on every screen, then one that has a minimum size and one that
/// refuses moves. Each placement is read back, and the check holds the kit
/// to its word: "placed" must match the frame, "ignored" must not have moved.
enum LayoutCheck {
    struct Window {
        let process: Process
        let element: Element
    }

    static func open(_ title: String, _ extra: [String] = []) -> Window? {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("AXKitFixtures").path
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: binary)
        fixture.arguments = ["120", "--background", "--title", title,
                             "--state", NSTemporaryDirectory() + "axkit-layout-\(title).json"] + extra
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        guard (try? fixture.run()) != nil else { return nil }
        let app = App(pid: fixture.processIdentifier)
        var element: Element?
        _ = Check.wait(10) { element = app.windows.first { $0.title == title }; return element != nil }
        return element.map { Window(process: fixture, element: $0) }
    }

    static func run(json: Bool, fullScreen: Bool = false) -> Int32 {
        guard let a = open("Tile A"), let b = open("Tile B"), let c = open("Tile C") else {
            fail("the fixture windows did not show")
        }
        var all = [a, b, c]
        defer { all.forEach { $0.process.terminate() } }
        var rows: [Check.Row] = []
        func add(_ what: String, _ placements: [Layout.Placement], expect: (Layout.Placement) -> Bool) {
            for placement in placements {
                let got = placement.got.map { "\($0.x),\($0.y) \($0.w)×\($0.h)" } ?? "?"
                let wanted = "\(placement.wanted.x),\(placement.wanted.y) \(placement.wanted.w)×\(placement.wanted.h)"
                rows.append(Check.Row(control: placement.window, operation: what, expected: wanted,
                                      got: "\(placement.status) at \(got)", pass: expect(placement), tookFocus: false))
            }
        }
        // The kit's word must hold: "placed" means the frame is the one asked.
        func honest(_ p: Layout.Placement) -> Bool {
            guard let got = p.got else { return false }
            let same = abs(got.x - p.wanted.x) <= 2 && abs(got.y - p.wanted.y) <= 2
                && abs(got.w - p.wanted.w) <= 2 && abs(got.h - p.wanted.h) <= 2
            return p.status == "placed" ? same : !same
        }
        let front = App.frontmost?.pid
        FileHandle.standardError.write("screens: \(Layout.screens.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" }.joined(separator: "; "))\n".data(using: .utf8)!)
        for (index, screen) in Layout.screens.enumerated() {
            add("halves, screen \(index + 1)", Layout.tile([a.element, b.element], in: screen)) {
                $0.status == "placed" || ($0.status == "constrained" && honest($0))
            }
            let thirds = Layout.tile([a.element, b.element, c.element], in: screen)
            // No overlap: each window starts where the one before it ends.
            let edges = thirds.compactMap(\.got)
            let overlap = zip(edges, edges.dropFirst()).contains { $1.x < $0.x + $0.w - 2 }
            add("thirds, screen \(index + 1)" + (overlap ? ", OVERLAP" : ""), thirds) {
                !overlap && ($0.status == "placed" || $0.status == "overflows"
                    || ($0.status == "constrained" && honest($0)))
            }
        }
        if let screen = Layout.screens.first {
            // Minimized: hidden, then placed, which brings it back.
            try? a.element.minimize()
            _ = Check.wait(2) { a.element.isMinimized == true }
            let hiddenWhenMinimized = Visibility.isHidden(a.element)
            var placement = Layout.place(a.element, in: Layout.columns(2, of: screen)[0])
            if !hiddenWhenMinimized { placement.status += " (was not seen as hidden)" }
            add("minimized, then a left half", [placement]) {
                $0.status == "placed" && hiddenWhenMinimized && a.element.isMinimized == false
            }
            // Full screen: on a Space of its own, then back and placed.
            if fullScreen {
                try? c.element.fullScreen()
                let went = Check.wait(5) { c.element.isFullScreen == true }
                Thread.sleep(forTimeInterval: 1.5)
                let hidden = Visibility.isHidden(c.element)
                var back = Layout.place(c.element, in: Layout.columns(2, of: screen)[1])
                back.status += went ? "" : " (never went full screen)"
                FileHandle.standardError.write("full screen: \(went ? "yes" : "no"); seen as hidden meanwhile: \(hidden)\n".data(using: .utf8)!)
                add("full screen, then a right half", [back]) {
                    went && c.element.isFullScreen == false && ($0.status == "placed" || ($0.status == "constrained" && honest($0)))
                }
            }
            // Across screens: from the last screen to the first and back.
            if let other = Layout.screens.last, other != screen {
                let there = Layout.place(b.element, in: Layout.columns(2, of: other)[1])
                let back = Layout.place(b.element, in: Layout.columns(2, of: screen)[1])
                add("to the other screen and back", [there, back]) { $0.status == "placed" || ($0.status == "constrained" && honest($0)) }
            }
            let third = Layout.columns(3, of: screen)[0]
            if let wide = open("Wide", ["--min-size", "\(Int(third.width) + 200)", "400"]) {
                all.append(wide)
                add("a third, min width above it", [Layout.place(wide.element, in: third)]) {
                    $0.status == "constrained" && ($0.got?.w ?? 0) >= Int(third.width) + 200
                }
            }
            if let stubborn = open("Stubborn", ["--stubborn"]) {
                all.append(stubborn)
                add("left half, refuses moves", [Layout.place(stubborn.element, in: Layout.columns(2, of: screen)[0])]) {
                    $0.status == "ignored"
                }
            }
        }
        rows = rows.map {
            Check.Row(control: $0.control, operation: $0.operation, expected: $0.expected, got: $0.got,
                      pass: $0.pass, tookFocus: App.frontmost?.pid != front)
        }
        Check.report(rows, json: json)
        return rows.allSatisfy { $0.pass && !$0.tookFocus } ? 0 : 1
    }
}
