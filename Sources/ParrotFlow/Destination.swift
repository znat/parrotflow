import AppKit
import ApplicationServices

/// Whether the dictation has anywhere to land, decided at the press.
///
/// The pill shows the icon of the app the words are about to be typed into, and
/// "the app in front" is not that claim. A Finder window, a browser reading an
/// article, a full-screen video — all frontmost, none of them with a caret in
/// it. The paste still happens: ⌘V lands in whatever that window makes of it,
/// which is usually nothing and occasionally something nobody asked for, and
/// either way the sentence is gone, because it existed nowhere else.
///
/// So the question asked at the press is not who is in front but whether
/// anything in front has keyboard focus and takes text. The answer drives two
/// things that have to agree: the icon is drawn only when there is somewhere to
/// write, and when there is not, the transcript is copied and said out loud
/// instead of being fired into a window that will swallow it.
enum Destination: Equatable {

    /// Something with keyboard focus that will accept typed text, named by the
    /// accessibility role it reported — the log line is the only way to tell
    /// afterwards why a surface was accepted or refused.
    case field(role: String)

    /// A terminal, which is the one place the question cannot be asked.
    ///
    /// Its focused element is a view of the screen rather than a field: the
    /// value is the whole visible buffer and is read-only, so an editable-field
    /// test says no about the one surface in the system that is nothing but an
    /// input. `SelectionReader` has known this for as long as it has been
    /// writing corrections — a terminal takes keystrokes and refuses
    /// everything else, which is precisely what a paste is. So terminals are
    /// named rather than examined.
    case terminal(name: String)

    /// Nothing focused that would take text. The transcript goes to the
    /// clipboard instead.
    ///
    /// Spelled `nowhere` rather than `none` so that a `Destination?` never has
    /// two meanings for `.none`.
    case nowhere(Reason)

    /// Why there was nowhere to write. Carried apart from the message because
    /// one of these is not like the others: without the grant nothing can be
    /// typed anywhere, which the app has always reported in its own way.
    enum Reason: Equatable {
        case noAccessibility
        case nothingFocused
        case notAField(role: String)

        var described: String {
            switch self {
            case .noAccessibility: return "accessibility is not granted"
            case .nothingFocused: return "nothing has keyboard focus"
            case .notAField(let role): return "\(role) does not take text"
            }
        }
    }

    /// True when the words can be typed where they were aimed.
    var acceptsText: Bool {
        if case .nowhere = self { return false }
        return true
    }

    var described: String {
        switch self {
        case .field(let role): return "field (\(role))"
        case .terminal(let name): return "terminal (\(name))"
        case .nowhere(let reason): return "nowhere — \(reason.described)"
        }
    }

    /// What the press found.
    ///
    /// `focus` is the element `SelectionReader` captured a moment earlier in the
    /// same handler, so this asks accessibility nothing it has not already been
    /// asked — the snapshot is on the main thread against apps that can be slow
    /// to answer, and a second traversal for a second opinion is how a hotkey
    /// starts feeling late.
    static func at(app: Pipeline.App?, focus: AXUIElement?) -> Destination {
        // First, and ahead of the terminals, because without the grant there is
        // no focused element to inspect *and* no paste to aim: `TextInserter`
        // leaves the text on the clipboard whatever this says, terminal or not.
        // Answering honestly here is what keeps the pill's icon from promising
        // something the app cannot do.
        guard Permissions.accessibility == .granted else {
            return .nowhere(.noAccessibility)
        }

        if let app, let name = terminalName(of: app) { return .terminal(name: name) }

        guard let focus else { return .nowhere(.nothingFocused) }
        let role = SelectionReader.role(of: focus) ?? "an unnamed element"
        guard SelectionReader.acceptsTypedText(focus) else {
            return .nowhere(.notAField(role: role))
        }
        return .field(role: role)
    }

    /// The terminal in front, by name, or nil for anything else.
    ///
    /// A list rather than a test, because there is nothing to test: what makes a
    /// terminal a terminal is on the far side of a pty, and everything the
    /// accessibility API can see is a grid of characters — the same shape
    /// whether it is showing a shell prompt or the output of `cat`.
    ///
    /// Both halves are checked because one terminal is several bundles. Warp
    /// ships stable, preview and nightly under three identifiers, Alacritty has
    /// been `io.` and `org.` in living memory, and anything built from source
    /// signs itself however the build did — while the name in the menu bar
    /// stays what you call it. A list that only knew identifiers would silently
    /// stop recognising a terminal on the day its author renamed one.
    ///
    /// The exception is deliberately narrow either way: being wrong here costs
    /// a paste into a window that ignores it, which is what happened before any
    /// of this existed.
    static func terminalName(of app: Pipeline.App) -> String? {
        let bundle = app.bundleID.lowercased()
        let name = app.name.lowercased()
        if terminalBundleIDs.contains(bundle) || terminalNames.contains(name) {
            return app.described
        }
        return nil
    }

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "org.alacritty",
        "dev.warp.warp-stable",
        "dev.warp.warp-preview",
        "co.zeit.hyper",
        "com.raphaelamorim.rio",
        "org.tabby",
    ]

    private static let terminalNames: Set<String> = [
        "terminal",
        "iterm",
        "iterm2",
        "ghostty",
        "kitty",
        "wezterm",
        "alacritty",
        "warp",
        "hyper",
        "rio",
        "tabby",
    ]
}
