import AppKit

/// Whether a window shows any part of itself. Chromium and Electron stop
/// handling keys and clicks in a window other windows cover entirely: 3 of 13
/// cases passed covered, 13 of 13 with its occlusion throttling off (09-28).
public enum Visibility {
    /// True when no part of the window shows: covered by windows in front of
    /// it, minimized, off screen or on another Space. Reads the window list,
    /// which needs no permission for positions.
    /// `region`: only this part of the window, such as the field about to
    /// take keys. The whole window by default.
    public static func isHidden(_ window: Element, region: CGRect? = nil) -> Bool {
        guard let pid = window.pid, let windowFrame = window.frame, window.isMinimized != true else { return true }
        let frame = region?.intersection(windowFrame) ?? windowFrame
        if frame.isNull || frame.isEmpty { return true }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        func bounds(_ info: [String: Any]) -> CGRect? {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict as CFDictionary)
        }
        // Front to back: everything before the window is in front of it.
        guard let index = list.firstIndex(where: { info in
            (info[kCGWindowOwnerPID as String] as? Int32) == pid
                && (info[kCGWindowLayer as String] as? Int) == 0
                && bounds(info).map { abs($0.minX - windowFrame.minX) <= 2 && abs($0.minY - windowFrame.minY) <= 2
                    && abs($0.width - windowFrame.width) <= 2 && abs($0.height - windowFrame.height) <= 2 } == true
        }) else { return true }
        let covers = list[..<index].compactMap { info -> CGRect? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05 else { return nil }
            return bounds(info)
        }
        let screens = NSScreen.screens.isEmpty ? [] : Layout.screens
        let steps = 16
        for row in 0...steps {
            for column in 0...steps {
                let point = CGPoint(x: frame.minX + frame.width * CGFloat(column) / CGFloat(steps),
                                    y: frame.minY + frame.height * CGFloat(row) / CGFloat(steps))
                guard screens.contains(where: { $0.insetBy(dx: -1, dy: -40).contains(point) }) else { continue }
                if !covers.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }
}

/// Runs an action in front when it has to. A page (Chromium, Electron) in a
/// window nobody can see does not handle it; anything else stays in the
/// background. The app that was in front comes back after.
public enum Foreground {
    /// Whether an action on this element needs its app in front: it is in a
    /// page and its app is not in front. Measured 09-28: Chromium queues keys
    /// for a window it judges hidden, then ignores clicks too once it has
    /// been sent back behind; neither the window's nor the element's own
    /// visibility tells when it does. For a task of several steps, prefer
    /// `session`, which brings the app once instead of at every step.
    public static func needed(for element: Element) -> Bool {
        guard element.isInWebArea, let pid = element.pid else { return false }
        return !App(pid: pid).isFrontmost
    }

    /// `body` with the element's app in front if `needed`, then the previous
    /// front app back. The Bool tells the body whether it ran in front.
    public static func ifHidden<T>(_ element: Element, _ body: (Bool) throws -> T) throws -> T {
        guard needed(for: element) else { return try body(false) }
        return try always(element, body)
    }

    /// A task of several steps on one app, with the app in front for all of
    /// it when it has pages, then the previous front app back. Inside, no step
    /// needs to come in front on its own. Native apps stay in the background.
    public static func session<T>(_ app: App, pages: Bool, _ body: () throws -> T) throws -> T {
        guard pages, !app.isFrontmost else { return try body() }
        let front = App.frontmost
        guard app.activate() else { throw Input.Refusal.notFrontmost(expected: app.pid, actual: App.frontmost?.pid) }
        defer { if let front, front.pid != app.pid { front.activate() } }
        Thread.sleep(forTimeInterval: 0.3)
        return try body()
    }

    /// `body` with the element's app in front, then the previous front app back.
    public static func always<T>(_ element: Element, _ body: (Bool) throws -> T) throws -> T {
        guard let pid = element.pid else { return try body(false) }
        let front = App.frontmost
        let app = App(pid: pid)
        guard app.activate() else { throw Input.Refusal.notFrontmost(expected: pid, actual: App.frontmost?.pid) }
        defer { if let front, front.pid != pid { front.activate() } }
        // The page wakes up when it shows again: give it a moment.
        Thread.sleep(forTimeInterval: 0.3)
        return try body(true)
    }
}
