import AXKit
import ApplicationServices

/// Which reader reads an app's screen at the press. An override replaces the
/// generic reader for its app: the two never merge, so an override's output is
/// exactly its own.
enum ContextReader: String {
    case terminal, slack, generic

    static let slackBundleID = "com.tinyspeck.slackmacgap"

    /// Nil when no reader takes the app: it is neither a terminal nor Slack,
    /// and the generic reader is off.
    static func choose(for app: Pipeline.App, everyApp: Bool) -> ContextReader? {
        let profile = AppProfile.of(app)
        if profile.readsPane { return .terminal }
        if profile.readsTree { return .slack }
        return everyApp ? .generic : nil
    }
}

/// A terminal's accessibility value is its visible screen, so the whole read
/// is one call.
enum TerminalReader {
    static func read(from element: AXUIElement) -> Result<Context.Capture, Context.Declined> {
        guard let value = SelectionReader.visibleText(of: element) else {
            return .failure(.unreadable)
        }
        let above = Context.aboveInputBox(in: value)
        guard !above.isEmpty else { return .failure(.empty) }
        let (text, truncated) = Context.tail(of: above, limit: Context.maxChars)
        return .success(Context.Capture(text: text, truncated: truncated))
    }
}
