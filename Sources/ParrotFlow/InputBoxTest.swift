import AXKit
import ApplicationServices
import Foundation

/// `--tree-test`: which fields the `input` read refuses, and what
/// context spelling falls back to when it does.
enum InputBoxTest {

    private static let safari = Pipeline.App(name: "Safari", bundleID: "com.apple.Safari")

    private static func refused(_ app: Pipeline.App, owner: String?, readable: Bool = true) -> String {
        InputBox.refusal(app: app, owner: owner, readable: { readable }).map(\.rawValue) ?? "read"
    }

    private static func field(role: String, subrole: String?, subroleRead: AXError) -> String {
        refused(safari, owner: safari.bundleID,
                readable: Element.valueIsReadable(role: role, subrole: subrole, subroleRead: subroleRead))
    }

    /// Every denied app, by the bundle ID the press was for.
    static func everyDeniedApp() -> String {
        let read = ContextReader.deniedBundleIDs.sorted().filter {
            refused(Pipeline.App(name: "", bundleID: $0), owner: $0) != InputBox.Declined.denied.rawValue
        }
        return read.isEmpty ? "all denied" : "read: " + read.joined(separator: ", ")
    }

    /// A denied app is refused before its field is asked anything.
    static func deniedAsksNothing() -> String {
        var asked = false
        let app = Pipeline.App(name: "1Password", bundleID: "com.1password.1password")
        _ = InputBox.refusal(app: app, owner: app.bundleID, readable: { asked = true; return true })
        return asked ? "asked" : "not asked"
    }

    /// The press goes through `capturePress`, then context spelling looks for
    /// a fallback. Refused before any accessibility call, so it holds without
    /// the grant this binary does not have.
    static func spellingFallback() -> String {
        let run = 9_001
        _ = Context.begin(nil)
        InputBox.beginPress(run)
        InputBox.capturePress(run: run, app: Pipeline.App(name: "1Password", bundleID: "com.1password.1password"),
                              element: AXUIElementCreateSystemWide())
        let outcome: String
        switch InputBox.capture(for: run)?.outcome {
        case .failure(let why)?: outcome = why.rawValue
        case .success?: outcome = "read"
        case nil: outcome = "no slot"
        }
        let screen = PressReadTest.blocking {
            await ContextSpelling.captured(scope: Scope(values: ["press.run": .int(run)])).text
        }
        InputBox.forget(run)
        return "\(outcome); fallback ⟪\(screen)⟫"
    }

    static func run() -> Int32 {
        let denied = InputBox.Declined.denied.rawValue
        let secure = InputBox.Declined.secure.rawValue
        let checks: [(what: String, got: String, want: String)] = [
            ("every app in deniedBundleIDs", everyDeniedApp(), "all denied"),
            ("the bundle ID in any case",
             refused(Pipeline.App(name: "", bundleID: "com.1Password.1password"), owner: nil), denied),
            ("a password manager's panel over a browser", refused(safari, owner: "com.1password.1password"), denied),
            ("System Settings", refused(Pipeline.App(name: "", bundleID: "com.apple.systempreferences"),
                                        owner: nil), denied),
            ("a denied app is not asked about its field", deniedAsksNothing(), "not asked"),
            ("a text field in Safari", field(role: kAXTextFieldRole, subrole: nil, subroleRead: .noValue), "read"),
            ("an AXSecureTextField role",
             field(role: "AXSecureTextField", subrole: nil, subroleRead: .noValue), secure),
            ("an AXSecureTextField subrole",
             field(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, subroleRead: .success), secure),
            ("a subrole that cannot be read",
             field(role: kAXTextFieldRole, subrole: nil, subroleRead: .cannotComplete), secure),
            ("context spelling gets nothing from a denied field", spellingFallback(), "\(denied); fallback ⟪⟫"),
        ]
        return GenericReaderTest.report("input refusal", checks)
    }
}
