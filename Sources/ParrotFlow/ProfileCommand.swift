import Foundation

/// `--profile <bundle-id> [name]` — what `AppProfile` makes of an app.
///
/// The routing every dictation turns on, printed for one app, so a case file
/// can assert the table. Getting an entry wrong is silent in both directions: a
/// missing one sends every dictation in that app to the clipboard, and a wrong
/// one pastes without checking what has focus.
enum ProfileCommand {

    static func run(bundleID: String, name: String) -> Int32 {
        let profile = AppProfile.of(Pipeline.App(name: name, bundleID: bundleID))
        print("focus      \(profile.focus.rawValue)")
        print("anchor     \(profile.anchor.rawValue)")
        print("readsPane  \(profile.readsPane)")
        print("paste      \(profile.paste.rawValue)")
        return 0
    }
}
