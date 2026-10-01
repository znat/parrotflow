import AppKit
import ApplicationServices

/// Asks Chromium apps to build the accessibility tree they keep switched off.
///
/// Electron apps take `AXManualAccessibility`, a Chromium convention, not an
/// Apple API. Google Chrome refuses it with -25205 and takes
/// `AXEnhancedUserInterface` instead. Without the tree the app reports no
/// focused element (-25212), which reads as "nothing to type into" and sends
/// the transcript to the clipboard.
///
/// The flag lives on the pid, so it dies with the process and a relaunched app
/// must be asked again. Codex answers -25205 and cannot be unlocked this way;
/// Slack and Notion expose a tree without being asked.
enum ChromiumAccessibility {

    /// Logged once per process. Deliberately does not gate the call: an app can
    /// activate before its accessibility element exists, and a set keyed on
    /// "asked" would remember that failure as a success and never retry.
    private static var announced: Set<pid_t> = []

    /// One delayed second attempt per process, for an app that activates before
    /// it is ready. Bounded because native apps refuse this for ever.
    private static var retried: Set<pid_t> = []

    /// Browsers that refuse the manual flag and take the enhanced one. One line
    /// per measured build: the enhanced flag also changes how window managers
    /// and the page behave, so it is never set on an app nobody measured.
    ///
    /// Chrome 154, 2026-10-01: the focused element answers 1–2 s after the flag
    /// is set, not at once.
    private static let enhancedBundleIDs: Set<String> = ["com.google.Chrome"]

    static func askIfNeeded(_ app: NSRunningApplication?) {
        guard let app, Permissions.accessibility == .granted else { return }
        let pid = app.processIdentifier

        let element = AXUIElementCreateApplication(pid)
        // Called at the press too, on the main thread. The default is ~6 s.
        AXUIElementSetMessagingTimeout(element, 0.25)
        let manual = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )

        var built = manual == .success
        if manual == .attributeUnsupported,
           enhancedBundleIDs.contains(app.bundleIdentifier ?? "") {
            if isEnhanced(element) { return }
            // Returns -25208 whether or not it took. Only the read-back tells.
            AXUIElementSetAttributeValue(
                element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
            )
            built = isEnhanced(element)
        }

        guard built else {
            if retried.insert(pid).inserted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { askIfNeeded(app) }
            }
            return
        }

        guard announced.insert(pid).inserted else { return }
        Log.write("accessibility: asked \(app.localizedName ?? "pid \(pid)") to build its tree")
    }

    private static func isEnhanced(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXEnhancedUserInterface" as CFString, &value)
        return (value as? Bool) == true
    }

    static func forget(_ app: NSRunningApplication?) {
        guard let app else { return }
        announced.remove(app.processIdentifier)
        retried.remove(app.processIdentifier)
    }
}
