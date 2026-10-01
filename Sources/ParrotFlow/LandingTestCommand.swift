import Foundation

/// `--landing-test` — checks `Destination.pastesLate`, the second look at
/// focus when the words of a press with nowhere to type are ready.
enum LandingTestCommand {

    static func run() -> Int32 {
        let app: pid_t = 501
        let other: pid_t = 502
        let field = Destination.LateFocus(
            accessibility: true, front: app, owner: app, takesText: true, ours: false
        )
        var otherApp = field
        otherApp.front = other
        otherApp.owner = other
        var otherOwner = field
        otherOwner.owner = other
        var notAField = field
        notAField.takesText = false
        var ours = field
        ours.ours = true
        var noGrant = field
        noGrant.accessibility = false

        let cases: [(String, Destination.Reason, pid_t?, Destination.LateFocus, Bool)] = [
            ("same app, a field now: paste", .nothingFocused(nil), app, field, true),
            ("same app, was not a field, a field now: paste",
             .notAField(role: "AXWebArea"), app, field, true),
            ("another app in front: copy", .nothingFocused(nil), app, otherApp, false),
            ("the field belongs to another app: copy", .nothingFocused(nil), app, otherOwner, false),
            ("same app, still not a field: copy", .nothingFocused(nil), app, notAField, false),
            ("our own panel: copy", .nothingFocused(nil), app, ours, false),
            ("no Accessibility at the press: copy", .noAccessibility, app, field, false),
            ("no Accessibility at landing: copy", .nothingFocused(nil), app, noGrant, false),
            ("no app at the press: copy", .nothingFocused(nil), nil, field, false),
        ]

        var failures = 0
        for (name, reason, pid, found, want) in cases {
            let got = Destination.pastesLate(after: reason, pressedIn: pid, found: found)
            print("\(got == want ? "✓" : "✗") \(name)")
            if got != want { failures += 1 }
        }
        print(failures == 0 ? "\(cases.count)/\(cases.count)" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
