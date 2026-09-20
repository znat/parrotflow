import AppKit
import ApplicationServices

/// What is on screen around a point, in the shape a model can read.
///
/// A port of the gaze prototype's `tools/axsnap.swift`, moved in here because
/// ParrotFlow already holds the Accessibility grant that walk needs and a
/// second binary would need its own. The item shape is unchanged on purpose:
/// a snapshot this writes can be read by `tools/jev_probe.py`, and the
/// snapshot that scored 8/8 on 2026-09-20 can be read by this. Same file,
/// same decision, or the port is wrong.
///
/// It reads one window — the one under the point — and not the screen. A
/// window is what an instruction is about, it is what the accessibility API
/// is fast at, and the alternative is every window of every app for a
/// sentence that names one thing.
enum ScreenTargets {

    // MARK: - The shape

    /// One thing on screen worth naming out loud.
    ///
    /// `x`/`y` are the centre and `w`/`h` the size, in accessibility
    /// coordinates, because that is what a click needs. `cm` is the distance
    /// from the point to the nearest *edge*, so anything the gaze is inside of
    /// is 0 rather than however wide it happens to be.
    struct Item: Codable, Equatable {
        var kind: String
        var role: String
        var name: String
        var value: String
        var cm: Double
        var x: Int
        var y: Int
        var w: Int
        var h: Int
        var actions: [String]

        var point: CGPoint { CGPoint(x: Double(x), y: Double(y)) }
        var isClickable: Bool { kind == Kind.click || kind == Kind.text }
    }

    enum Kind {
        static let click = "click"
        static let text = "text"
        static let label = "label"
        static let other = "other"
    }

    struct Rect: Codable, Equatable { var x: Int; var y: Int; var w: Int; var h: Int }
    struct Spot: Codable, Equatable { var x: Int; var y: Int }

    struct Snapshot: Codable, Equatable {
        var app: String
        var window: String
        var pointer: Spot
        var pxPerCm: Int
        var frame: Rect
        var items: [Item]

        /// Where an item sits down the window, 0 at the top and 1 at the
        /// bottom. The composer and the search field are told apart by this
        /// and nothing else — neither carries a name.
        func relativeY(of item: Item) -> Double {
            Double(item.y - frame.y) / Double(max(frame.h, 1))
        }

        var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        static func read(fromFile path: String) throws -> Snapshot {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        }
    }

    enum Failure: LocalizedError {
        case notTrusted
        case nothingThere(CGPoint)
        case noSuchApp(String)

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Accessibility is not granted, so nothing on screen can be read."
            case .nothingThere(let p):
                return "Nothing at \(Int(p.x)),\(Int(p.y)) — the desktop, or a window that publishes nothing."
            case .noSuchApp(let name):
                return "\(name) is not running."
            }
        }
    }

    // MARK: - Taking one

    /// Everything in the window under `point`.
    ///
    /// `ignoring` holds app names whose windows are not what anyone means —
    /// the gaze overlay draws its dot at exactly the point being asked about,
    /// so a hit test there finds the tracker rather than the window under it.
    /// Measured by the prototype: a gaze at the control panel's corner
    /// returned "GazeOverlay"; over the dot it returned the app below,
    /// because that window ignores mouse events. Which flag does it was never
    /// isolated, so the pid is skipped rather than the flag trusted.
    static func snapshot(
        at point: CGPoint, ignoring ignored: Set<String> = [], budget: Int = 8000
    ) throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard let found = windowUnder(point, ignoring: ignored) else {
            throw Failure.nothingThere(point)
        }
        return walk(found.window, pid: found.pid, pointer: point, budget: budget)
    }

    /// The front window of a named app, wherever the pointer is. `--app` in
    /// the prototype: it is how a snapshot is taken of something that is not
    /// in front, and how the same window can be snapshotted twice.
    static func snapshot(
        ofApp name: String, at point: CGPoint, budget: Int = 8000
    ) throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || $0.bundleIdentifier == name
        }) else { throw Failure.noSuchApp(name) }
        let pid = running.processIdentifier
        wake(pid)
        let app = AXUIElementCreateApplication(pid)
        let window = (attribute(app, kAXFocusedWindowAttribute) as! AXUIElement?)
            ?? (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { throw Failure.nothingThere(point) }
        return walk(window, pid: pid, pointer: point, budget: budget)
    }

    // MARK: - Finding the window

    private static func windowUnder(
        _ point: CGPoint, ignoring ignored: Set<String>
    ) -> (window: AXUIElement, pid: pid_t)? {
        if let hit = hitTest(point), !skip(hit.pid, ignored) {
            return hit
        }
        // The hit test landed on something nobody meant. Take the frontmost
        // window at that point that belongs to somebody else, and ask its app
        // for it — `CGWindowListCopyWindowInfo` is front to back.
        for pid in pidsAt(point) where !skip(pid, ignored) {
            wake(pid)
            let app = AXUIElementCreateApplication(pid)
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let window = windows.first(where: { frame(of: $0)?.contains(point) == true }) {
                return (window, pid)
            }
            if let focused = attribute(app, kAXFocusedWindowAttribute) as! AXUIElement? {
                return (focused, pid)
            }
        }
        return nil
    }

    private static func hitTest(_ point: CGPoint) -> (window: AXUIElement, pid: pid_t)? {
        let system = AXUIElementCreateSystemWide()
        var under: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &under) == .success,
              let element = under else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        wake(pid)
        var current = element
        for _ in 0..<60 {
            if string(current, kAXRoleAttribute) == kAXWindowRole { return (current, pid) }
            guard let parent = attribute(current, kAXParentAttribute) else { break }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// The pids owning on-screen windows containing the point, front first.
    private static func pidsAt(_ point: CGPoint) -> [pid_t] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let listing = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var pids: [pid_t] = []
        for window in listing {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
                  CGRect(x: x, y: y, width: w, height: h).contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  !pids.contains(pid)
            else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// Our own windows are never the target. The pill floats over whatever is
    /// being dictated into, which is precisely where somebody is looking when
    /// they say what to do about it.
    private static func skip(_ pid: pid_t, _ ignored: Set<String>) -> Bool {
        pid == getpid() || ignored.contains(name(of: pid))
    }

    private static func name(of pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
    }

    /// An Electron window publishes almost nothing until it is asked to.
    /// Measured by the prototype: without this the first walk of Slack comes
    /// back nearly empty.
    private static func wake(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - The walk

    private struct Found {
        let frame: CGRect
        let kind: String
        let name: String
        let role: String
        let value: String
        let actions: [String]
    }

    private static func walk(
        _ window: AXUIElement, pid: pid_t, pointer: CGPoint, budget: Int
    ) -> Snapshot {
        var found: [Found] = []
        var left = budget
        let windowFrame = frame(of: window) ?? .zero
        collect(window, into: &found, budget: &left)

        let scale = pixelsPerCm(at: pointer)
        // A container is not a target: at some size it holds the thing meant
        // rather than being it. 12 % of the window is where the prototype put
        // the line.
        let tooBig = windowFrame.width * windowFrame.height * 0.12
        var items: [Item] = []
        for item in found {
            guard item.frame.width * item.frame.height <= tooBig else { continue }
            let blank = item.name.trimmingCharacters(in: .whitespaces).isEmpty
                && item.value.trimmingCharacters(in: .whitespaces).isEmpty
            // A nameless text field is still a target — the composer has no
            // name anywhere. A nameless anything else cannot be asked for.
            guard !blank || item.kind == Kind.text else { continue }
            items.append(
                Item(
                    kind: item.kind, role: item.role, name: item.name, value: item.value,
                    cm: (distance(from: pointer, to: item.frame) / scale * 10).rounded() / 10,
                    x: Int(item.frame.midX), y: Int(item.frame.midY),
                    w: Int(item.frame.width), h: Int(item.frame.height),
                    actions: item.actions.filter { $0 != "AXScrollToVisible" }
                )
            )
        }
        items.sort { $0.cm < $1.cm }

        // A row and the group inside it carry the same name and nearly the
        // same frame. Keep the outer one, which is what a click wants.
        var kept: [Item] = []
        for item in items {
            let duplicate = kept.contains {
                $0.name == item.name && $0.kind == item.kind
                    && abs($0.x - item.x) < 20 && abs($0.y - item.y) < 20
            }
            if !duplicate { kept.append(item) }
        }

        return Snapshot(
            app: name(of: pid),
            window: string(window, kAXTitleAttribute) ?? "",
            pointer: Spot(x: Int(pointer.x), y: Int(pointer.y)),
            pxPerCm: Int(scale),
            frame: Rect(
                x: Int(windowFrame.minX), y: Int(windowFrame.minY),
                w: Int(windowFrame.width), h: Int(windowFrame.height)
            ),
            items: kept
        )
    }

    /// Walks the subtree and returns its visible text.
    ///
    /// The return value is the point of the recursion: Slack's rows and
    /// buttons carry no title of their own, and their name is in the static
    /// texts underneath them. Without this, half a window is nameless.
    @discardableResult
    private static func collect(
        _ element: AXUIElement, into out: inout [Found], depth: Int = 0, budget: inout Int
    ) -> String {
        guard depth < 40, budget > 0 else { return "" }
        budget -= 1
        let role = string(element, kAXRoleAttribute) ?? "?"
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var text = ""
        for child in children {
            let below = collect(child, into: &out, depth: depth + 1, budget: &budget)
            if !below.isEmpty && text.count < 120 {
                text += (text.isEmpty ? "" : " ") + below
            }
        }
        let own = string(element, kAXValueAttribute) ?? ""
        if role == kAXStaticTextRole && !own.trimmingCharacters(in: .whitespaces).isEmpty {
            text = own
        }
        if let box = frame(of: element), box.width > 2, box.height > 2, box.width < 3000 {
            let actions = actionNames(element)
            if let kind = kindOf(role: role, actions: actions, children: children.count) {
                var name = string(element, kAXTitleAttribute)
                    ?? string(element, kAXDescriptionAttribute)
                    ?? string(element, "AXPlaceholderValue") ?? ""
                if name.isEmpty { name = string(element, kAXHelpAttribute) ?? "" }
                if name.isEmpty && kind != Kind.label { name = text }
                let value = (kind == Kind.label || kind == Kind.text) ? own : ""
                out.append(
                    Found(
                        frame: box, kind: kind, name: clean(name), role: role,
                        value: clean(value), actions: actions
                    )
                )
            }
        }
        return text
    }

    private static func kindOf(role: String, actions: [String], children: Int) -> String? {
        if role == kAXTextFieldRole || role == kAXTextAreaRole
            || role == kAXComboBoxRole || role == "AXSearchField" { return Kind.text }
        if actions.contains(kAXPressAction) || actions.contains(kAXConfirmAction) { return Kind.click }
        if role == kAXStaticTextRole { return Kind.label }
        // Something that does its own thing and holds nothing that could have
        // been meant instead.
        let real = actions.filter {
            $0 != "AXScrollToVisible" && $0 != "AXShowMenu" && $0 != "AXRaise" && !$0.hasPrefix("AXScroll")
        }
        if !real.isEmpty && children == 0 { return Kind.other }
        return nil
    }

    private static func clean(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }

    /// To the nearest edge, so a point inside something is 0 away from it.
    private static func distance(from point: CGPoint, to box: CGRect) -> Double {
        let dx = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = max(box.minY - point.y, 0, point.y - box.maxY)
        return hypot(dx, dy)
    }

    /// Centimetres are what the model is told, because a distance in pixels
    /// means nothing without a screen size and a distance in cm is something
    /// anybody has an intuition for. 47 is a fallback for a display that does
    /// not report its physical size.
    private static func pixelsPerCm(at point: CGPoint) -> Double {
        let primary = NSScreen.screens.first?.frame ?? .zero
        let flipped = NSPoint(x: point.x, y: primary.maxY - point.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(flipped) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return 47 }
        let mm = CGDisplayScreenSize(number)
        guard mm.width > 100 else { return 47 }
        return screen.frame.width / (mm.width / 10)
    }

    // MARK: - Accessibility plumbing

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? (names as? [String] ?? []) : []
    }
}
