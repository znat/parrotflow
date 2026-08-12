import AppKit
import ApplicationServices

/// Asks Chromium apps to build the accessibility tree they keep switched off.
///
/// `AXManualAccessibility` is a Chromium convention, not an Apple API. Without
/// it VS Code reports no focused element and no focused application, which
/// reads as "nothing to type into" and sends the transcript to the clipboard.
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

    static func askIfNeeded(_ app: NSRunningApplication?) {
        guard let app, Permissions.accessibility == .granted else { return }
        let pid = app.processIdentifier

        let element = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )

        guard result == .success else {
            if retried.insert(pid).inserted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { askIfNeeded(app) }
            }
            return
        }

        guard announced.insert(pid).inserted else { return }
        Log.write("accessibility: asked \(app.localizedName ?? "pid \(pid)") to build its tree")
    }

    static func forget(_ app: NSRunningApplication?) {
        guard let app else { return }
        announced.remove(app.processIdentifier)
        retried.remove(app.processIdentifier)
    }
}
