import AppKit
import ApplicationServices

/// A running app, seen through accessibility.
public struct App: Sendable {
    public let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }

    /// By bundle identifier, else by name, ignoring case.
    public static func named(_ name: String) -> App? {
        // NSWorkspace's list is not refreshed in a process that runs no event
        // loop: an app launched after the first call never appears (09-29).
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: name).first {
            return App(pid: app.processIdentifier)
        }
        let apps = NSWorkspace.shared.runningApplications
        let found = apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
        return found.map { App(pid: $0.processIdentifier) }
    }

    /// Asked of accessibility first: NSWorkspace's answer goes stale in a
    /// process that runs no event loop, such as a command-line tool.
    public static var frontmost: App? {
        focused ?? NSWorkspace.shared.frontmostApplication.map { App(pid: $0.processIdentifier) }
    }

    /// The app with the keyboard focus. Spotlight or a system dialog has it
    /// while the frontmost app stays the same.
    public static var focused: App? {
        Element(AXUIElementCreateSystemWide()).element(kAXFocusedApplicationAttribute)?.pid.map(App.init)
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public var running: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    public var name: String? { running?.localizedName }
    public var bundleIdentifier: String? { running?.bundleIdentifier }
    /// Asked of accessibility: NSWorkspace's answer goes stale in a process
    /// that runs no event loop, such as a command-line tool.
    public var isFrontmost: Bool {
        element.bool(kAXFrontmostAttribute) ?? (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
    }

    public var element: Element { Element(AXUIElementCreateApplication(pid)) }

    /// Chromium and Electron publish almost nothing until asked: the first
    /// walk of Slack without this comes back nearly empty.
    public func wake() {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Starts the app, or finds it running. With `background`, it does not
    /// come in front and keeps no focus from anyone.
    public static func launch(bundle: String, background: Bool = true, timeout: Double = 15) throws -> App {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            return App(pid: running.processIdentifier)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            throw AXKitError.appNotFound(bundle)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        configuration.addsToRecentItems = false
        var launched: NSRunningApplication?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            (launched, failure) = (app, error)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let launched else {
            throw failure ?? AXKitError.appNotFound(bundle)
        }
        return App(pid: launched.processIdentifier)
    }

    /// Opens a URL (a file, or a link into an app such as `slack://…`)
    /// without bringing its app in front.
    public static func open(_ url: URL, background: Bool = true) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    /// Brings the app in front and says whether it is. This takes the
    /// focus: a foreground step. Since macOS 14 an app may not activate
    /// another unless it is active itself, so accessibility's AXFrontmost is
    /// tried first, then NSRunningApplication.activate, then Launch Services,
    /// as `open -b` does. The app says it is frontmost before its menus
    /// follow: wait for the item itself to be enabled (Safari, 09-29).
    /// Which try brought the app in front last: "accessibility",
    /// "NSRunningApplication", "Launch Services", or nil when none did.
    nonisolated(unsafe) public static var lastActivation: String?

    @discardableResult
    public func activate(timeout: Double = 2) -> Bool {
        App.lastActivation = nil
        try? element.set(kAXFrontmostAttribute, to: kCFBooleanTrue)
        if waitFrontmost(timeout) { App.lastActivation = "accessibility"; return true }
        running?.activate()
        if waitFrontmost(0.5) { App.lastActivation = "NSRunningApplication"; return true }
        // Launch Services picks the instance by bundle: with two running
        // (a throwaway Chrome beside the user's), it could pick the other.
        guard let bundle = bundleIdentifier, let url = running?.bundleURL,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundle).count == 1 else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + timeout)
        guard waitFrontmost(timeout) else { return false }
        App.lastActivation = "Launch Services"
        return true
    }

    /// Until the app says it is frontmost and the system gives it the
    /// focus, which comes later: keys sent between go to the old app.
    func waitFrontmost(_ timeout: Double) -> Bool {
        let front = { self.isFrontmost && App.focused?.pid == self.pid }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if front() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return front()
    }

    /// The window becomes the app's main one and is raised within the app,
    /// without bringing the app in front.
    public func raise(_ window: Element) throws {
        try window.set(kAXMainAttribute, to: kCFBooleanTrue)
        try window.perform(kAXRaiseAction)
    }

    public var windows: [Element] { element.elements(kAXWindowsAttribute) }
    public var focusedWindow: Element? { element.element(kAXFocusedWindowAttribute) }
    public var mainWindow: Element? { element.element(kAXMainWindowAttribute) }
    public var focusedElement: Element? { element.element(kAXFocusedUIElementAttribute) }

    /// The element under a screen point, in this app only. Unlike the
    /// system-wide hit test, an overlay drawn by another app does not hide it.
    public func element(at point: CGPoint) -> Element? {
        App.hit(AXUIElementCreateApplication(pid), point)
    }

    /// The element with this frame (within `tolerance` points), found by
    /// walking the windows rather than by hit test, so a window in front does
    /// not hide it. Where several share the frame, the first that `prefer`
    /// accepts wins: a group can have its field's frame.
    public func element(framed box: CGRect, tolerance: CGFloat = 2, budget: Int = 20_000,
                        prefer: (Element) -> Bool = { _ in true }) -> Element? {
        let centre = CGPoint(x: box.midX, y: box.midY)
        func same(_ frame: CGRect) -> Bool {
            abs(frame.midX - box.midX) <= tolerance && abs(frame.midY - box.midY) <= tolerance
                && abs(frame.width - box.width) <= tolerance && abs(frame.height - box.height) <= tolerance
        }
        var queue = windows
        var left = budget
        var first: Element?
        while !queue.isEmpty, left > 0 {
            let element = queue.removeFirst()
            left -= 1
            let frame = element.frame
            if let frame, same(frame) {
                if prefer(element) { return element }
                first = first ?? element
            }
            if let frame, !frame.insetBy(dx: -4, dy: -4).contains(centre) { continue }
            queue.append(contentsOf: element.children)
        }
        return first
    }

    /// The topmost element under a screen point, whatever app owns it.
    public static func element(at point: CGPoint) -> Element? {
        hit(AXUIElementCreateSystemWide(), point)
    }

    private static func hit(_ root: AXUIElement, _ point: CGPoint) -> Element? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &found) == .success,
              let found else { return nil }
        return Element(found)
    }
}
