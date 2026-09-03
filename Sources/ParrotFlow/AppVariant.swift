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

    /// `~/Library/Application Support/ParrotFlow` or `.../ParrotFlow Dev`.
    ///
    /// For what the app downloads rather than for what a person edits — the
    /// config directory holds files somebody opens in an editor, and a 300 MB
    /// model cache does not belong next to them. Split per variant like
    /// everything else here.
    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(displayName, isDirectory: true)
    }

    static var defaultOutputDir: String {
        isDev ? "~/Recordings/ParrotFlow Dev" : "~/Recordings/ParrotFlow"
    }

    /// Right ⌥ for dev, Right ⌘ for release, so both builds can run at once
    /// and you choose which one hears you by which key you hold. Both are
    /// bare modifiers, which is what push-to-talk wants.
    static var defaultHotkey: String {
        isDev ? "right_option" : "right_command"
    }

    /// The parrot this build sits in the menu bar with when nothing is happening.
    ///
    /// Both builds show the same bird — it is the app's mark, and giving the one
    /// you develop against a different animal means the icon you look at all day
    /// is not the icon you ship. Colour tells them apart instead, because two
    /// identical parrots in the menu bar with no way to tell them apart is worse
    /// than one.
    ///
    /// The released app gets the template, which follows the menu bar into light
    /// and dark and is the only one of the three that does. The dev build gives
    /// that up for sky — a build you can pick out of the bar at a glance is worth
    /// more on the machine it is being written on than one that themes politely.
    static var menuBarIdleImage: String {
        isDev ? "MenuBarParrotDev" : "MenuBarParrotTemplate"
    }

    /// Scarlet, in both builds, for as long as the microphone is open.
    static let menuBarRecordingImage = "MenuBarParrotRecording"

    // MARK: About

    static let repository = "https://github.com/znat/parrotflow"

    /// Read from the bundle rather than from `version.txt`, so the number in the
    /// About panel is the one this build was stamped with by `release.sh`.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// The commit this bundle was built from, written into Info.plist by
    /// `scripts/build-app.sh`. `--version` prints it and the app logs it at
    /// launch, so a measurement can prove which code produced it. A stale
    /// install that looked current once cost a night of wrong conclusions.
    ///
    /// "unstamped" when the key is absent — the bare SwiftPM binary run outside
    /// a bundle. A `-dirty` suffix means the tree had uncommitted changes.
    static var buildStamp: String {
        Bundle.main.object(forInfoDictionaryKey: "PFBuildStamp") as? String ?? "unstamped"
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

    /// What the app contains: the repository line, then every model it fetches
    /// and every library that fetches or runs one.
    ///
    /// The About panel is the one surface that names a program this app did not
    /// write, and it is the only place the licences are stated. Two paragraph
    /// styles: the repository line stays centred, and a centred list is
    /// unreadable, so everything under it goes left.
    ///
    /// Only models this build actually fetches are named. eSpeak NG is set
    /// apart because it is the one name here that is not shipped and not
    /// downloaded — nothing is distributed, so no GPL source offer applies; it
    /// is named because the app runs it.
    static var credits: NSAttributedString {
        let left = NSMutableParagraphStyle()
        left.alignment = .natural
        left.paragraphSpacing = 3

        let credits = NSMutableAttributedString(attributedString: repositoryLink)
        credits.append(NSAttributedString(string: "\n\n"))

        func line(_ text: String, size: CGFloat = 10.5, bold: Bool = false, dim: Bool = false) {
            credits.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bold
                    ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: left,
            ]))
        }

        /// A name in bold, then what it does and what it is under.
        func item(_ name: String, _ role: String) {
            let entry = NSMutableAttributedString(
                string: name,
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 10.5),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: left,
                ]
            )
            entry.append(NSAttributedString(string: " — \(role)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: left,
            ]))
            credits.append(entry)
        }

        line("BUILT WITH", size: 9, bold: true, dim: true)
        item("Parakeet TDT 0.6B v3", "speech recognition · CC BY 4.0")
        item("Silero VAD", "finds where speech is · MIT")
        item("CharsiuG2P", "pronunciations, for matching your terms by sound")
        // Two lines because the code and the weights are not under the same
        // terms, and the weights the app fetches are not the upstream ones.
        line(
            "MIT for the code · the Core ML weights it fetches are Apache 2.0;"
                + " the upstream weights state no licence",
            size: 10, dim: true
        )
        item("ModernBERT", "sentence boundaries · Apache 2.0")
        item("Qwen3 Embedding 0.6B", "word vectors for the vocabulary gate · Apache 2.0")
        item("MLX", "runs Qwen3 Embedding · MIT")
        item("FluidAudio", "fetching and Core ML plumbing · Apache 2.0")

        credits.append(NSAttributedString(string: "\n"))
        item(
            "eSpeak NG",
            "GPL-3.0. Not distributed with ParrotFlow. If you install it yourself,"
                + " ParrotFlow runs it as a separate program and reads its output."
        )
        line("github.com/espeak-ng/espeak-ng", size: 10, dim: true)

        return credits
    }
}
