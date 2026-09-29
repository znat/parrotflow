import AppKit

/// Windows placed on screens: halves, thirds, a given frame. Everything is in
/// accessibility's coordinates: points, origin at the top left of the main
/// screen, y growing down. Each placement is read back, because a window can
/// refuse a move while the call succeeds (the Finder did, 09-28) or stop at
/// its minimum size.
public enum Layout {
    public struct Placement: Codable, Sendable {
        public var window: String
        public var wanted: Rect
        public var got: Rect?
        /// "placed", "constrained" (the size stopped short), "ignored" (it did
        /// not move), "overflows" (laid side by side, it runs off the area),
        /// or "failed".
        public var status: String
    }

    /// Each screen's usable area, without the menu bar and the Dock, main
    /// screen first.
    public static var screens: [CGRect] {
        guard let main = NSScreen.screens.first?.frame else { return [] }
        return NSScreen.screens.map { screen in
            let area = screen.visibleFrame
            return CGRect(x: area.minX, y: main.maxY - area.maxY, width: area.width, height: area.height)
        }
    }

    /// The usable area of the screen that holds most of the window.
    public static func screen(of window: Element) -> CGRect? {
        guard let frame = window.frame else { return screens.first }
        return screens.max { $0.intersection(frame).area < $1.intersection(frame).area }
    }

    /// `count` side-by-side columns of `area`, left to right.
    public static func columns(_ count: Int, of area: CGRect) -> [CGRect] {
        let width = (area.width / CGFloat(count)).rounded(.down)
        return (0..<count).map { CGRect(x: area.minX + CGFloat($0) * width, y: area.minY, width: width, height: area.height) }
    }

    /// Moves and sizes the window to `frame`, and says what it became. Move,
    /// size, then move again: a window pushed against a screen edge can
    /// refuse a size until it has moved.
    @discardableResult
    public static func place(_ window: Element, in frame: CGRect, tolerance: CGFloat = 2) -> Placement {
        let name = window.title ?? "?"
        // A minimized window has no place to move: bring it back first.
        let restored = window.isMinimized == true
        if restored {
            try? window.minimize(false)
            _ = Controls.wait { window.isMinimized == false }
            // A size set during the restore animation does not stay (09-29).
            var last = window.frame
            _ = Controls.wait {
                Thread.sleep(forTimeInterval: 0.1)
                defer { last = window.frame }
                return window.frame == last
            }
        }
        let before = window.frame
        // With AXEnhancedUserInterface on, which `App.wake` sets for Chromium
        // and Electron, such apps ignore a new size and most of a move (the
        // window-manager tools found the same). Off while placing, then back.
        let app = window.pid.map { App(pid: $0).element }
        let enhanced = app?.bool("AXEnhancedUserInterface") == true
        if enhanced { try? app?.set("AXEnhancedUserInterface", to: kCFBooleanFalse) }
        defer {
            if enhanced {
                try? app?.set("AXEnhancedUserInterface", to: kCFBooleanTrue)
                // Chromium rebuilds its tree when it is switched back on: wait
                // until the window's page can be read again.
                _ = Controls.wait { window.first(budget: 400, where: { $0.role == "AXWebArea" }) != nil }
            }
        }
        do {
            try window.move(to: frame.origin)
            try window.resize(to: frame.size)
            try window.move(to: frame.origin)
        } catch {
            return Placement(window: name, wanted: Rect(frame), got: window.frame.map(Rect.init), status: "failed")
        }
        // Electron applies a size in steps: read until two reads agree.
        var got = window.frame
        _ = Controls.wait {
            Thread.sleep(forTimeInterval: 0.05)
            let now = window.frame
            defer { got = now }
            return now == got && now.map { close($0, frame, tolerance) } == true
        }
        got = window.frame
        // Nothing changed at all: some apps apply a frame late, others take
        // the second request only. Read again after a moment, then ask again.
        if let now = got, let before, now == before, !close(now, frame, tolerance) {
            Thread.sleep(forTimeInterval: 0.5)
            if window.frame == before {
                try? window.move(to: frame.origin)
                try? window.resize(to: frame.size)
                try? window.move(to: frame.origin)
                _ = Controls.wait { window.frame.map { close($0, frame, tolerance) } == true }
            }
            got = window.frame
        }
        guard let got else { return Placement(window: name, wanted: Rect(frame), got: nil, status: "failed") }
        // Stopped under a screen's menu bar, which a second screen's visible
        // frame leaves out: the top moved down and the height shrank by the
        // same amount. That is the frame the screen allows: placed.
        var frame = frame
        let drop = got.minY - frame.minY
        if abs(got.minX - frame.minX) <= tolerance, drop > tolerance, drop < 80,
           abs((frame.height - got.height) - drop) <= tolerance, abs(got.width - frame.width) <= tolerance {
            frame = CGRect(x: frame.minX, y: got.minY, width: frame.width, height: got.height)
        }
        let status: String
        // Ignored: it stayed where it was, far from where it was sent. A few
        // points short, as under a screen's menu bar, is constrained.
        let far = abs(got.minX - frame.minX) > 40 || abs(got.minY - frame.minY) > 40
        if close(got, frame, tolerance) {
            status = "placed"
        } else if far, let before, abs(got.minX - before.minX) < 1, abs(got.minY - before.minY) < 1 {
            status = "ignored"
        } else {
            status = "constrained"
        }
        // Just restored from the Dock, a window can drop the first size it is
        // given while its animation ends (09-29): once more.
        if restored, status != "placed" {
            Thread.sleep(forTimeInterval: 0.5)
            return place(window, in: frame, tolerance: tolerance)
        }
        return Placement(window: name, wanted: Rect(frame), got: Rect(got), status: status)
    }

    /// The windows side by side across `area` (the first window's screen by
    /// default), in the order given.
    public static func tile(_ windows: [Element], in area: CGRect? = nil) -> [Placement] {
        guard let first = windows.first, var area = area ?? screen(of: first) else { return [] }
        var placements = zip(windows, columns(windows.count, of: area)).map { place($0, in: $1) }
        // A second screen's menu bar is not in its visible frame (09-29: 30
        // points on a Dell beside a MacBook). When every window stops the same
        // way below the top, that is the real top: place again under it.
        let drops = placements.compactMap { p in p.got.map { $0.y - p.wanted.y } }
        if drops.count == placements.count, let drop = drops.min(), drop > 2, drop < 80,
           drops.allSatisfy({ $0 == drop }) {
            area = CGRect(x: area.minX, y: area.minY + CGFloat(drop), width: area.width,
                          height: area.height - CGFloat(drop))
            placements = zip(windows, columns(windows.count, of: area)).map { place($0, in: $1) }
        }
        // Windows wider than their column: side by side from the left edge,
        // so they do not overlap. What does not fit then says so.
        if placements.contains(where: { ($0.got?.w ?? 0) > $0.wanted.w + 2 }) {
            var x = area.minX
            placements = zip(windows, placements).map { window, first in
                let width = CGFloat(first.got?.w ?? first.wanted.w)
                let frame = CGRect(x: x, y: area.minY, width: width, height: area.height)
                x += width
                var placement = place(window, in: frame)
                if frame.maxX > area.maxX + 2 { placement.status = "overflows" }
                return placement
            }
        }
        return placements
    }

    static func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
