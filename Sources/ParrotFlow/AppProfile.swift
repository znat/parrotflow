import Foundation

/// What an app affords, decided from its identity rather than by asking it.
///
/// One entry per app, instead of the same app appearing in a list in
/// `Destination`, a branch in `CaretAnchor` and a special case in
/// `AppDelegate`.
struct AppProfile: Equatable {

    enum Focus: String {
        /// Ask what has focus and refuse anything that does not take text.
        case examine
        /// A terminal: its focused element is the screen, so an editable-field
        /// test says no about a surface that is nothing but an input.
        case screen
        /// Answers nothing. The system hands back whatever app participated
        /// last, so the answer is about somebody else's window.
        case blind
    }

    enum Anchor: String {
        case ladder
        /// The bottom of the app's own window, read from the window server.
        case window
    }

    var focus: Focus
    var anchor: Anchor
    /// Whether the visible text can be handed to the pipeline. See `Context`.
    var readsPane: Bool

    static let ordinary = AppProfile(focus: .examine, anchor: .ladder, readsPane: false)
    static let terminal = AppProfile(focus: .screen, anchor: .ladder, readsPane: true)
    static let blind = AppProfile(focus: .blind, anchor: .window, readsPane: false)

    /// Bundle id and name both, because one terminal is several bundles and
    /// Codex is one bundle called ChatGPT.
    static func of(_ app: Pipeline.App) -> AppProfile {
        let bundle = app.bundleID.lowercased()
        let name = app.name.lowercased()
        if terminalBundleIDs.contains(bundle) || terminalNames.contains(name) { return .terminal }
        if blindBundleIDs.contains(bundle) || blindNames.contains(name) { return .blind }
        return .ordinary
    }

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty", "org.alacritty",
        "dev.warp.warp-stable", "dev.warp.warp-preview", "co.zeit.hyper",
        "com.raphaelamorim.rio", "org.tabby",
    ]

    private static let terminalNames: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "kitty", "wezterm", "alacritty",
        "warp", "hyper", "rio", "tabby",
    ]

    /// An app belongs here only once two things are measured: that
    /// `ChromiumAccessibility` fails on it, and that a ⌘V into it lands. Codex
    /// answers -25205 to `AXManualAccessibility` and -25208 to
    /// `AXEnhancedUserInterface`.
    private static let blindBundleIDs: Set<String> = ["com.openai.codex"]

    private static let blindNames: Set<String> = ["codex"]
}
