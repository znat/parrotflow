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

    /// Which rich pasteboard flavour this app is known to take. Plain text
    /// always rides along beside it, so this names only what goes on the item
    /// as well.
    enum Paste: String {
        /// Plain text and nothing else. What an app gets until it is measured.
        case plain
        case html
        case rtf

        /// What `Markup.item` writes, over and above the plain fallback.
        var flavours: [Markup.Flavour] {
            switch self {
            case .plain: return []
            case .html: return [.html]
            case .rtf: return [.rtf]
            }
        }
    }

    var focus: Focus
    var anchor: Anchor
    /// Whether the visible text can be handed to the pipeline. See `Context`.
    var readsPane: Bool
    var paste: Paste

    static let ordinary = AppProfile(
        focus: .examine, anchor: .ladder, readsPane: false, paste: .plain)
    static let terminal = AppProfile(
        focus: .screen, anchor: .ladder, readsPane: true, paste: .plain)
    static let blind = AppProfile(
        focus: .blind, anchor: .window, readsPane: false, paste: .plain)

    /// Terminals by bundle id or name, because one terminal is several bundles
    /// and anything built from source signs itself however the build did.
    /// Blind apps by bundle id alone: the list is one measured build each, and
    /// a name is something any app can claim.
    ///
    /// A terminal and a blind app return before the paste lookup is reached, so
    /// neither can be promoted out of plain text by adding a line to a set
    /// below. That is deliberate: a terminal renders no markup and shows the
    /// tags instead, and a blind app is one nothing about is known by asking.
    static func of(_ app: Pipeline.App) -> AppProfile {
        let bundle = app.bundleID.lowercased()
        let name = app.name.lowercased()
        if terminalBundleIDs.contains(bundle) || terminalNames.contains(name) { return .terminal }
        if blindBundleIDs.contains(bundle) { return .blind }

        var profile = AppProfile.ordinary
        profile.paste = pasteFlavour(bundle: bundle)
        return profile
    }

    private static func pasteFlavour(bundle: String) -> Paste {
        if htmlBundleIDs.contains(bundle) { return .html }
        if rtfBundleIDs.contains(bundle) { return .rtf }
        return .plain
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
    /// `AXEnhancedUserInterface`. Its name is "ChatGPT", so the bundle id is
    /// the only thing that identifies it.
    private static let blindBundleIDs: Set<String> = ["com.openai.codex"]

    /// An app belongs in one of these only once the matrix in
    /// docs/proposals/formatted-paste.md scores it, with `--paste-probe` and a
    /// real window. Not measured means plain, which is the answer that cannot
    /// lose a sentence.
    ///
    /// Bundle id alone, for the reason `blindBundleIDs` is: each line is one
    /// measured build, and a name is something any app can claim. Terminals are
    /// the exception in this file because a terminal really is built from
    /// source and signed however the build did. Slack is not.
    ///
    /// Measured 2026-08-24: Slack takes `public.html` whole — bold, italic, a
    /// code span, bullets, a real second level, an ordered list, and a link on
    /// its own words.
    private static let htmlBundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]

    private static let rtfBundleIDs: Set<String> = []
}
