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
    /// tried first; NSRunningApplication.activate is the fallback.
    @discardableResult
    public func activate(timeout: Double = 2) -> Bool {
        try? element.set(kAXFrontmostAttribute, to: kCFBooleanTrue)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if isFrontmost { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        running?.activate()
        Thread.sleep(forTimeInterval: 0.3)
        return isFrontmost
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
