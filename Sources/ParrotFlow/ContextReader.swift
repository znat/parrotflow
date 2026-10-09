import AXKit
import ApplicationServices

/// Which reader reads an app's screen at the press. An override replaces the
/// generic reader for its app: the two never merge, so an override's output is
/// exactly its own.
enum ContextReader: String {
    case terminal, slack, generic

    static let slackBundleID = "com.tinyspeck.slackmacgap"

    /// `notReadable` when no reader takes the app: it is neither a terminal
    /// nor Slack, and the generic reader is off. `denied` for an app that is
    /// never read.
    static func choose(for app: Pipeline.App, everyApp: Bool) -> Result<ContextReader, Context.Declined> {
        let profile = AppProfile.of(app)
        if profile.readsPane { return .success(.terminal) }
        if profile.readsTree { return .success(.slack) }
        guard everyApp else { return .failure(.notReadable) }
        guard !deniedBundleIDs.contains(app.bundleID.lowercased()) else { return .failure(.denied) }
        return .success(.generic)
    }

    /// Whether the focused element belongs to the app the press was for. The
    /// focus is looked up system-wide, so a floating panel from another
    /// process (a password manager over a browser, an auth prompt) can hold it.
    /// Nil when it does.
    static func check(owner: String?, of app: Pipeline.App) -> Context.Declined? {
        guard let owner, owner.lowercased() == app.bundleID.lowercased() else {
            return owner.map { deniedBundleIDs.contains($0.lowercased()) } == true ? .denied : .appChanged
        }
        return nil
    }

    /// Never read: they hold passwords, the system's settings, or ask for a
    /// password. Lower case. Fixed here; a list users can extend is for later.
    static let deniedBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.apple.passwords", "com.apple.keychainaccess", "com.apple.systempreferences",
        "org.keepassxc.keepassxc", "me.proton.pass.electron", "in.sinew.enpass-desktop.app",
        "com.apple.securityagent", "com.apple.localauthentication.uiagent",
    ]
}

/// A terminal's accessibility value is its visible screen, so the whole read
/// is one call.
enum TerminalReader {
    static func read(from element: AXUIElement) -> Result<Context.Capture, Context.Declined> {
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard Element(element).valueIsReadable, let value = SelectionReader.visibleText(of: element) else {
            return .failure(.unreadable)
        }
        let above = Context.aboveInputBox(in: value)
        guard !above.isEmpty else { return .failure(.empty) }
        let (text, truncated) = Context.tail(of: above, limit: Context.maxChars)
        return .success(Context.Capture(text: text, truncated: truncated))
    }
}
