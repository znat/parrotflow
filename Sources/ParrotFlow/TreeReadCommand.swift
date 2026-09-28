import AppKit
import ApplicationServices

/// `--tree-read <bundle-id>` — what the `context` stage would publish for an
/// app's front window, without that app being in front.
///
/// `--peek` reads whatever is frontmost, which is the right question when the
/// dictation is about to land there. It is the wrong tool for measuring an
/// app's tree: bringing the app forward to look at it is a race against
/// anything else that wants focus, and an overlay window wins it.
///
/// This reads by process id instead. It takes the app's focused element and the
/// window holding it, so it answers for the conversation that app is showing
/// rather than for the one you are dictating into.
enum TreeReadCommand {

    static func run(bundleID: String) -> Int32 {
        guard Permissions.accessibility == .granted else {
            print("✗ accessibility is not granted")
            return 1
        }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            print("✗ not running: \(bundleID)")
            return 1
        }
        ChromiumAccessibility.askIfNeeded(app)

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let started = Date()
        let focused = element(root, kAXFocusedUIElementAttribute)
        // `kAXWindowsAttribute` has no guaranteed order, so its first entry can
        // be a different window from the one holding the pane.
        guard let window = focused.flatMap(TreeContext.window(of:))
                ?? element(root, kAXFocusedWindowAttribute)
                ?? element(root, kAXWindowsAttribute) else {
            print("✗ no window")
            return 1
        }
        let pane = focused.flatMap(TreeContext.conversation(around:)) ?? window
        let assembled = TreeContext.assemble(
            TreeContext.nodes(under: pane), title: TreeContext.title(of: window))
        let roster = TreeContext.roster(in: window)
        let ms = Date().timeIntervalSince(started) * 1000

        print(String(format: "%@ — %.0fms", app.localizedName ?? bundleID, ms))
        print("place   \(assembled.place)")
        print("people  \(assembled.people.joined(separator: "; "))")
        print("code    \(assembled.code.joined(separator: "; "))")
        print("roster  \(roster.joined(separator: "; "))")
        print("text    \(assembled.text.count) chars")
        for row in assembled.text.components(separatedBy: "\n").prefix(40) {
            print("  | \(row)")
        }
        return 0
    }

    /// One element, or the first of a list of them.
    private static func element(_ root: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, name as CFString, &value) == .success,
              let value else { return nil }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! AXUIElement) }
        return (value as? [AXUIElement])?.first
    }
}
