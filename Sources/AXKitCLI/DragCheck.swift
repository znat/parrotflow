import AXKit
import AppKit
import Foundation

/// `axkit check --drag`: a foreground check. Temporary files are shown in a
/// Finder window, a target window is put beside it, and the files are
/// dragged with the real pointer onto the target's drop zone: the native
/// fixture's, or the Electron fixture's (as Slack or Teams take files). The
/// Finder window and the targets are closed after. Hands off the mouse.
enum DragCheck {
    struct Scene {
        let name: String
        /// "icon" or "list": the Finder's view.
        let view: String
        let files: Int
        /// "native" or "electron".
        let target: String
    }

    static let scenes = [
        Scene(name: "one file, icon view, native zone", view: "icon", files: 1, target: "native"),
        Scene(name: "one file, list view, native zone", view: "list", files: 1, target: "native"),
        Scene(name: "two files, list view, native zone", view: "list", files: 2, target: "native"),
        Scene(name: "one file, icon view, Electron zone", view: "icon", files: 1, target: "electron"),
        Scene(name: "a file out of an app, Electron zone", view: "app", files: 1, target: "electron"),
    ]

    static func run(json: Bool, only: String?) -> Int32 {
        let front = App.frontmost
        var rows: [Check.Row] = []
        for scene in scenes where only == nil || scene.name.contains(only!) {
            stopIfLocked()
            rows.append(play(scene))
        }
        front?.activate()
        if json {
            Check.report(rows, json: true)
        } else {
            for row in rows {
                print("\(row.pass ? "ok  " : "FAIL") \(row.operation): expected \(row.expected), got \(row.got)")
            }
            print("-- \(rows.filter(\.pass).count)/\(rows.count), a foreground check: the Finder and the target came in front, then the app that was")
        }
        return rows.allSatisfy(\.pass) ? 0 : 1
    }

    static func say(_ text: String) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }

    static func play(_ scene: Scene) -> Check.Row {
        let tag = "axkit-drag-\(ProcessInfo.processInfo.processIdentifier)-\(scene.view)-\(scene.files)-\(scene.target)"
        let folder = URL(fileURLWithPath: NSTemporaryDirectory() + tag)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = (0..<scene.files).map { "axkit-drag-\(["a", "b", "c"][$0]).txt" }
        let files = names.map { folder.appendingPathComponent($0) }
        files.forEach { try? "dragged by axkit\n".write(to: $0, atomically: true, encoding: .utf8) }
        var row = Check.Row(control: "drag", operation: scene.name, expected: "→ \(names.joined(separator: ", "))",
                            got: "not run", pass: false, tookFocus: false)

        // The target: its window, its drop zone, and how to read what it got.
        var closeTarget: () -> Void = {}
        var finderWindow: Element?
        defer {
            if let close = finderWindow?.first(budget: 50, where: { $0.subrole == kAXCloseButtonSubrole }) {
                try? close.perform(kAXPressAction)
            }
            closeTarget()
            try? FileManager.default.removeItem(at: folder)
        }
        let target: App
        let targetWindow: Element
        var zone: Element
        let dropped: () -> [String]
        let products = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        if scene.target == "native" {
            let state = NSTemporaryDirectory() + tag + ".json"
            let fixture = Process()
            fixture.executableURL = products.appendingPathComponent("AXKitFixtures")
            fixture.arguments = ["120", "--state", state]
            fixture.standardOutput = FileHandle.nullDevice
            guard (try? fixture.run()) != nil else { row.got = "no fixture"; return row }
            closeTarget = { fixture.terminate() }
            target = App(pid: fixture.processIdentifier)
            guard Check.wait(10, { Check.window(target)?.first(where: { $0.identifier == "file_zone" }) != nil }),
                  let window = Check.window(target), let found = window.first(where: { $0.identifier == "file_zone" })
            else { row.got = "the fixture did not show"; return row }
            (targetWindow, zone) = (window, found)
            dropped = { (Check.truth(state)?["dropped_files"] as? [String] ?? []).sorted() }
        } else {
            let folderApp = FileManager.default.currentDirectoryPath + "/Fixtures/electron-app"
            let binary = folderApp + "/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"
            let profile = NSTemporaryDirectory() + tag + "-profile"
            let electron = Process()
            electron.executableURL = URL(fileURLWithPath: binary)
            electron.arguments = [folderApp, "--user-data-dir=\(profile)"]
            electron.standardOutput = FileHandle.nullDevice
            electron.standardError = FileHandle.nullDevice
            guard (try? electron.run()) != nil else { row.got = "no Electron (npm install?)"; return row }
            closeTarget = {
                electron.terminate()
                try? FileManager.default.removeItem(atPath: profile)
            }
            target = App(pid: electron.processIdentifier)
            _ = Check.wait(15) { target.windows.contains { Glob.matches("Web controls*", $0.title ?? "") } }
            target.wake()
            guard Check.wait(10, { WebCheck.truth(target)?["ready"] as? Bool == true }),
                  let window = target.windows.first(where: { Glob.matches("Web controls*", $0.title ?? "") }),
                  let found = try? WebCheck.byDom(target, "drop_zone")
            else { row.got = "the Electron window did not show"; return row }
            (targetWindow, zone) = (window, found)
            dropped = { (WebCheck.truth(target)?["dropped_files"] as? [String] ?? []).sorted() }
        }

        if scene.view == "app" { return appToApp(scene, row: row, target: target, targetWindow: targetWindow,
                                                  zone: zone, dropped: dropped) }

        // The Finder, with the files selected, in the scene's view.
        NSWorkspace.shared.activateFileViewerSelecting(files)
        guard let finder = App.named("com.apple.finder") else { row.got = "no Finder"; return row }
        _ = Check.wait(10) {
            finderWindow = finder.windows.first { $0.title == folder.lastPathComponent }
            return finderWindow != nil
        }
        guard let finderWindow else { row.got = "the Finder did not show the folder"; return row }
        _ = finder.activate()
        try? finder.raise(finderWindow)
        if let item = Controls.menuItem(shortcut: scene.view == "list" ? "2" : "1", in: finder) {
            try? item.perform(kAXPressAction)
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Side by side on the main screen, target to the right.
        let area = Layout.screens.first ?? .zero
        Layout.place(finderWindow, in: CGRect(x: area.minX + 20, y: area.minY + 20, width: 700, height: 500))
        if let finderFrame = finderWindow.frame {
            let x = finderFrame.maxX + 20
            Layout.place(targetWindow, in: CGRect(x: x, y: area.minY + 20, width: max(700, area.maxX - x - 20),
                                                  height: area.height - 40))
        }
        _ = target.activate()
        _ = finder.activate()
        try? finder.raise(finderWindow)
        Thread.sleep(forTimeInterval: 0.4)
        // Placing a Chromium window rebuilds its tree: find the zone again.
        if scene.target == "electron", let again = try? WebCheck.byDom(target, "drop_zone") { zone = again }

        // Where the Finder starts a drag: the icon of a list row, or of an
        // icon view's item. The middle of a row's name is the list itself.
        let named = { (e: Element) in e.valueText == names[0] || e.name == names[0] }
        let list = finderWindow.first(budget: 3000, where: {
            [kAXOutlineRole, kAXListRole, kAXTableRole].contains($0.role ?? "") && $0.first(budget: 500, where: named) != nil
        })
        let item = list?.first(budget: 2000, where: {
            [kAXRowRole, "AXCell", kAXGroupRole].contains($0.role ?? "") && $0.first(budget: 20, where: named) != nil
        })
        guard let item else { row.got = "no \(names[0]) in the Finder's \(scene.view) view"; return row }
        let icon = item.first(budget: 20, where: { $0.role == kAXImageRole })?.visibleFrame
        let grip = icon.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? item.visibleFrame.map { CGPoint(x: $0.minX + 28, y: $0.midY) }
        if scene.files > 1, list?.role == kAXOutlineRole {
            let rows = list?.elements(kAXRowsAttribute) ?? []
            let chosen = rows.enumerated().filter { _, row in
                names.contains { name in row.first(budget: 20, where: { $0.valueText == name || $0.name == name }) != nil }
            }.map(\.offset)
            if let list { try? Controls.select(rows: chosen, in: list) }
        }
        say("\(scene.name): from the \(item.role ?? "?") at \(grip.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?")")

        let board = NSPasteboard(name: .drag)
        let count = board.changeCount
        do {
            try Input.drag(from: item, at: grip, to: zone)
            _ = Check.wait(3) { dropped() == names.sorted() }
            let got = dropped()
            row.pass = got == names.sorted()
            row.got = got.isEmpty
                ? "nothing dropped (a drag session \(board.changeCount != count ? "started" : "never started"))"
                : "→ \(got.joined(separator: ", "))"
        } catch {
            row.got = "stopped: \(error)"
        }
        return row
    }

    /// From the native fixture's drag source to the target's zone: two apps,
    /// no Finder.
    static func appToApp(_ scene: Scene, row: Check.Row, target: App, targetWindow: Element, zone: Element,
                         dropped: () -> [String]) -> Check.Row {
        var row = row
        row.expected = "→ axkit-from-app.txt"
        let products = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let fixture = Process()
        fixture.executableURL = products.appendingPathComponent("AXKitFixtures")
        fixture.arguments = ["120", "--title", "Source", "--state", NSTemporaryDirectory() + "axkit-drag-source.json"]
        fixture.standardOutput = FileHandle.nullDevice
        guard (try? fixture.run()) != nil else { row.got = "no fixture"; return row }
        defer { fixture.terminate() }
        let source = App(pid: fixture.processIdentifier)
        var window: Element?
        var handle: Element?
        _ = Check.wait(10) {
            window = source.windows.first { $0.title == "Source" }
            handle = window?.first(where: { $0.identifier == "drag_source" || $0.name == "axkit-from-app.txt" })
            return handle != nil
        }
        guard let window, handle != nil else { row.got = "the source did not show"; return row }
        let area = Layout.screens.first ?? .zero
        Layout.place(window, in: CGRect(x: area.minX + 20, y: area.minY + 20, width: 900, height: area.height - 40))
        if let frame = window.frame {
            let x = frame.maxX + 20
            Layout.place(targetWindow, in: CGRect(x: x, y: area.minY + 20, width: max(700, area.maxX - x - 20),
                                                  height: area.height - 40))
        }
        _ = target.activate()
        _ = source.activate()
        Thread.sleep(forTimeInterval: 0.4)
        var zone = zone
        if let again = try? WebCheck.byDom(target, "drop_zone") { zone = again }
        guard let pull = window.first(where: { $0.identifier == "drag_source" || $0.name == "axkit-from-app.txt" }) else {
            row.got = "no handle"; return row
        }
        do {
            try Input.drag(from: pull, to: zone)
            _ = Check.wait(3) { dropped() == ["axkit-from-app.txt"] }
            let got = dropped()
            row.pass = got == ["axkit-from-app.txt"]
            row.got = got.isEmpty ? "nothing dropped" : "→ \(got.joined(separator: ", "))"
        } catch {
            row.got = "stopped: \(error)"
        }
        return row
    }
}
