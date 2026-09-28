import AXKit
import AppKit
import Foundation

/// `axkit check --drag`: a foreground check. A temporary file is shown in a
/// Finder window, the fixture window is put beside it, and the file is
/// dragged with the real pointer onto the fixture's drop zone. The Finder
/// window the check opened is closed after. Do not touch the mouse meanwhile.
enum DragCheck {
    static func run(json: Bool) -> Int32 {
        let products = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let binary = products.appendingPathComponent("AXKitFixtures").path
        guard FileManager.default.isExecutableFile(atPath: binary) else { fail("no fixture app at \(binary)") }
        let state = NSTemporaryDirectory() + "axkit-drag-\(ProcessInfo.processInfo.processIdentifier).json"
        let folder = URL(fileURLWithPath: NSTemporaryDirectory() + "axkit-drag-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("axkit-drag.txt")
        try? "dragged by axkit\n".write(to: file, atomically: true, encoding: .utf8)

        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: binary)
        fixture.arguments = ["120", "--state", state]
        fixture.standardOutput = FileHandle.nullDevice
        do { try fixture.run() } catch { fail("could not start the fixture: \(error)") }
        let app = App(pid: fixture.processIdentifier)
        var finderWindow: Element?
        defer {
            if let close = finderWindow?.first(budget: 50, where: { $0.subrole == kAXCloseButtonSubrole }) {
                try? close.perform(kAXPressAction)
            }
            fixture.terminate()
            try? FileManager.default.removeItem(at: folder)
        }
        guard Check.wait(10, { Check.truth(state) != nil && Check.window(app) != nil }),
              let window = Check.window(app),
              let zone = window.first(where: { $0.identifier == "file_zone" }) else {
            fail("the fixture window did not show in 10 s")
        }

        NSWorkspace.shared.activateFileViewerSelecting([file])
        let finder = App.named("com.apple.finder")!
        var source: Element?
        _ = Check.wait(10) {
            finderWindow = finder.windows.first { ($0.title ?? "").hasPrefix("axkit-drag") }
            source = finderWindow?.first(budget: 2000) {
                ($0.role == kAXTextFieldRole || $0.role == kAXStaticTextRole || $0.role == kAXImageRole)
                    && ($0.valueText == file.lastPathComponent || $0.name == file.lastPathComponent)
            }
            return source != nil
        }
        guard let finderWindow, source != nil else { fail("the Finder did not show the file in 10 s") }

        // Side by side, so each point shows its own window on top.
        // Side by side. A move can return success and be ignored (the Finder
        // did, 09-28), so the fixture goes beside where the Finder window is.
        try? finderWindow.resize(to: CGSize(width: 520, height: 420))
        try? finderWindow.move(to: CGPoint(x: 40, y: 80))
        _ = Check.wait(1) { finderWindow.frame?.minX == 40 }
        if let finderFrame = finderWindow.frame, let fixtureFrame = window.frame {
            let screen = NSScreen.screens.first?.frame ?? .zero
            let x = finderFrame.maxX + 20 + fixtureFrame.width <= screen.width
                ? finderFrame.maxX + 20 : max(0, finderFrame.minX - 20 - fixtureFrame.width)
            try? window.move(to: CGPoint(x: x, y: max(40, min(finderFrame.minY, screen.height - fixtureFrame.height))))
        }
        let fixtureFront = app.activate()
        let finderFront = finder.activate()
        if !fixtureFront || !finderFront {
            FileHandle.standardError.write("could not bring in front: \(fixtureFront ? "" : "the fixture ")\(finderFront ? "" : "the Finder")\n".data(using: .utf8)!)
        }
        // Activating the Finder brings all its windows: the check's own goes
        // on top of the others.
        do { try finder.raise(finderWindow) } catch {
            FileHandle.standardError.write("raise failed: \(error)\n".data(using: .utf8)!)
        }
        Thread.sleep(forTimeInterval: 0.3)
        func where_(_ e: Element) -> String { e.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?" }
        FileHandle.standardError.write(("Finder window \"\(finderWindow.title ?? "")\" at \(where_(finderWindow)), main: \(finderWindow.bool(kAXMainAttribute).map(String.init) ?? "?")"
            + "; fixture at \(where_(window)); Finder's focused window: \"\(finder.focusedWindow?.title ?? "none")\"\n").data(using: .utf8)!)
        // Measured 09-28: the middle of a list row's name hit-tests as the
        // list itself, and pressing there starts a selection rectangle. The
        // row's icon, near its left edge, starts a drag.
        let named = { (e: Element) in e.valueText == file.lastPathComponent || e.name == file.lastPathComponent }
        // The row inside the file list: the same name also shows in the
        // path bar, outside the list.
        // The sidebar is an outline too, and comes first: the list is the one
        // that holds the file.
        let list = finderWindow.first(budget: 3000, where: {
            ($0.role == kAXOutlineRole || $0.role == kAXListRole || $0.role == kAXTableRole)
                && $0.first(budget: 500, where: named) != nil
        })
        // A list view has rows; an icon view has one group per file, its icon
        // and its name.
        let row = list?.first(budget: 2000, where: {
            ($0.role == kAXRowRole || $0.role == "AXCell" || $0.role == kAXGroupRole)
                && $0.first(budget: 20, where: named) != nil
        })
        if row == nil, let list {
            let seen = list.children.prefix(6).map { "\($0.role ?? "?")[\($0.children.map { $0.role ?? "?" }.joined(separator: ","))]" }
            FileHandle.standardError.write("no row for the file in \(list.role ?? "?"): \(seen.joined(separator: " "))\n".data(using: .utf8)!)
        }
        source = row ?? finderWindow.first(budget: 2000, where: named)
        var grip: CGPoint?
        if let row, let frame = row.frame {
            let icon = row.first(budget: 20, where: { $0.role == kAXImageRole })?.frame
            grip = icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: frame.minX + 28, y: frame.midY)
        }
        FileHandle.standardError.write("drag from \(source?.role ?? "?") at \(grip.map { "\(Int($0.x)),\(Int($0.y))" } ?? "its middle")\n".data(using: .utf8)!)

        var got = "no change"
        var pass = false
        let dragBoard = NSPasteboard(name: .drag)
        let dragCount = dragBoard.changeCount
        if let frame = source?.frame {
            let top = App.element(at: grip ?? CGPoint(x: frame.midX, y: frame.midY))
            FileHandle.standardError.write(("under the start: \(top?.role ?? "nothing") \"\(top?.name ?? top?.valueText ?? "")\""
                + " of \(top?.pid.flatMap { App(pid: $0).name } ?? "?"); Finder in front: \(finder.isFrontmost)\n").data(using: .utf8)!)
        }
        if let frame = zone.visibleFrame {
            FileHandle.standardError.write("zone frame \(zone.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?"), visible \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))\n".data(using: .utf8)!)
            let top = App.element(at: CGPoint(x: frame.midX, y: frame.midY))
            FileHandle.standardError.write("under the drop: \(top?.role ?? "nothing") \"\(top?.identifier ?? top?.name ?? "")\" at \(Int(frame.midX)),\(Int(frame.midY))\n".data(using: .utf8)!)
        }
        defer {
            FileHandle.standardError.write("the zone saw: \((Check.truth(state)?["drag_seen"] as? [String])?.joined(separator: ", ") ?? "nothing")\n".data(using: .utf8)!)
            let started = dragBoard.changeCount != dragCount
            FileHandle.standardError.write(("a drag session started: \(started ? "yes" : "no")"
                + (started ? ", carrying \(dragBoard.types?.map(\.rawValue).prefix(4).joined(separator: ", ") ?? "")" : "") + "\n").data(using: .utf8)!)
        }
        do {
            try Input.drag(from: source!, at: grip, to: zone)
            _ = Check.wait(2) { (Check.truth(state)?["dropped_files"] as? [String]) == [file.lastPathComponent] }
            let dropped = Check.truth(state)?["dropped_files"] as? [String] ?? []
            pass = dropped == [file.lastPathComponent]
            got = dropped.isEmpty ? "nothing dropped" : "→ \(dropped.joined(separator: ", "))"
        } catch {
            got = "stopped: \(error)"
        }
        let rows = [Check.Row(control: "file_zone", operation: "Input.drag a file from the Finder",
                              expected: "→ \(file.lastPathComponent)", got: got, pass: pass, tookFocus: false)]
        if json {
            Check.report(rows, json: true)
        } else {
            let row = rows[0]
            print("\(row.pass ? "ok  " : "FAIL") \(row.control) \(row.operation): expected \(row.expected), got \(row.got)")
            print("-- a foreground check: the Finder and the fixture came in front, then the app that was")
        }
        return pass ? 0 : 1
    }
}
