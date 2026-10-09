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
/// This reads by process id instead, through the same `Context.readTree` the
/// stage uses. It starts from the app's focused element, so it answers for the
/// conversation that app is showing rather than for the one you are dictating
/// into.
enum TreeReadCommand {

    static func run(bundleID: String, compare runs: Int? = nil) -> Int32 {
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
        let focused = element(root, kAXFocusedUIElementAttribute)
        // `kAXWindowsAttribute` has no guaranteed order, so its first entry can
        // be a different window from the one holding the pane.
        guard let window = focused.flatMap(TreeContext.window(of:))
                ?? element(root, kAXFocusedWindowAttribute)
                ?? element(root, kAXWindowsAttribute) else {
            print("✗ no window")
            return 1
        }
        // An app in the background reports nothing focused. Each composer is
        // then read as if the caret were in it.
        let starts = focused.map { [$0] } ?? TreeContext.composers(in: window)
        guard !starts.isEmpty else {
            print("✗ nothing is focused and the window has no composer")
            return 1
        }
        if let runs {
            return compare(app.localizedName ?? bundleID, starts: starts, runs: runs)
        }

        var read = false
        for start in starts {
            let started = Date()
            let outcome = Context.readTree(from: start)
            let ms = Date().timeIntervalSince(started) * 1000
            print(String(format: "%@ — %.0fms", app.localizedName ?? bundleID, ms))
            // The description, not the value: a composer's value is the draft.
            if focused == nil { print("from    \(description(of: start))") }
            switch outcome {
            case .failure(let why):
                print("✗ \(why.rawValue)")
            case .success(let got):
                read = true
                print("place   \(got.place)")
                print("people  \(got.people.joined(separator: "; "))")
                print("code    \(got.code.joined(separator: "; "))")
                print("roster  \(got.roster.joined(separator: "; "))")
                print("text    \(got.chars) chars"
                    + (got.truncated ? " (the last \(Context.maxChars))" : ""))
                for row in got.text.components(separatedBy: "\n").prefix(40) where !got.text.isEmpty {
                    print("  | \(row)")
                }
            }
        }
        return read ? 0 : 1
    }

    private static func description(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value)
        return value as? String ?? "a composer"
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
