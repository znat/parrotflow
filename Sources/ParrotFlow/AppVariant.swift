import AppKit
import Foundation

/// Which build this is — the one you are working on, or the one people install.
///
/// The two are separate applications as far as macOS is concerned, and that is
/// the point. Permissions are granted per bundle identifier, so a dev build that
/// shares an identifier with the released app is granting and revoking the
/// released app's microphone access every time it is rebuilt. Splitting the
/// identifier means work in progress cannot reach into a working install.
///
/// Everything that would otherwise collide is derived from here: the config
/// file, the log, where recordings land, and the hotkey. The hotkey matters most
/// — two builds listening to the same key both record the same sentence and both
/// paste it.
///
/// The variant is read from the bundle identifier rather than compiled in, so
/// one binary serves both and `scripts/build-app.sh` decides by writing a
/// different Info.plist.
enum AppVariant {

    static let isDev: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

    /// What to call it in windows and menus.
    static var displayName: String { isDev ? "ParrotFlow Dev" : "ParrotFlow" }

    /// `~/.config/parrotflow` or `~/.config/parrotflow-dev`.
    ///
    /// Separate rather than shared: a config written by a half-finished feature
    /// — a new key, a rule the correction panel saved wrong — should not be able
    /// to break the copy you rely on to get work done.
    static var configDirectory: String {
        isDev ? ".config/parrotflow-dev" : ".config/parrotflow"
    }

    static var logFileName: String {
        isDev ? "ParrotFlow-Dev.log" : "ParrotFlow.log"
    }

    static var defaultOutputDir: String {
        isDev ? "~/Recordings/ParrotFlow Dev" : "~/Recordings/ParrotFlow"
    }

    /// Right ⌘ for dev, so both builds can run at once and you choose which one
    /// hears you by which key you hold. Both are bare modifiers, which is what
    /// push-to-talk wants.
    static var defaultHotkey: String {
        isDev ? "right_command" : "right_option"
    }

    /// A different menu bar glyph, because two microphones in the menu bar with
    /// no way to tell them apart is worse than one.
    static var menuBarSymbol: String { isDev ? "mic.circle" : "mic" }
    static var menuBarSymbolRecording: String { isDev ? "mic.circle.fill" : "mic.fill" }

    // MARK: About

    static let repository = "https://github.com/znat/parrotflow"

    /// Read from the bundle rather than from `version.txt`, so the number in the
    /// About panel is the one this build was stamped with by `release.sh`.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// The repository as a clickable line for the standard About panel, which
    /// takes its credits as an attributed string.
    static var repositoryLink: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: centred,
        ]
        if let url = URL(string: repository) { attributes[.link] = url }

        return NSAttributedString(string: "github.com/znat/parrotflow", attributes: attributes)
    }
}
