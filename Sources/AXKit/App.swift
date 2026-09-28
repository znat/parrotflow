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
        let apps = NSWorkspace.shared.runningApplications
        let found = apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
        return found.map { App(pid: $0.processIdentifier) }
    }

    public static var frontmost: App? {
        NSWorkspace.shared.frontmostApplication.map { App(pid: $0.processIdentifier) }
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public var running: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    public var name: String? { running?.localizedName }
    public var bundleIdentifier: String? { running?.bundleIdentifier }
    public var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    public var element: Element { Element(AXUIElementCreateApplication(pid)) }

    /// Chromium and Electron publish almost nothing until asked: the first
    /// walk of Slack without this comes back nearly empty.
    public func wake() {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
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
