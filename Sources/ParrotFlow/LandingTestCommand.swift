import Foundation

/// `--landing-test` — checks the two rules for words that had nowhere to go:
/// `Destination.pastesLate`, the second look at focus when they are ready, and
/// `Destination.offersAfterHandPaste`, a ⌘V by hand while they wait on the
/// clipboard.
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
        var total = 0
        func check(_ name: String, _ got: Bool, _ want: Bool) {
            total += 1
            print("\(got == want ? "✓" : "✗") \(name)")
            if got != want { failures += 1 }
        }

        print("A press with nowhere to type, at landing")
        for (name, reason, pid, found, want) in cases {
            check(name, Destination.pastesLate(after: reason, pressedIn: pid, found: found), want)
        }

        print("A ⌘V by hand while \"On your clipboard\" is up")
        let words = "Ship it on Friday."
        func hand(_ ours: Bool, _ field: Bool, _ before: String?) -> Bool {
            Destination.offersAfterHandPaste(
                clipboardIsOurs: ours, field: field, before: before, pasted: words
            )
        }
        check("ours, a field, the words before the caret: offer", hand(true, true, words), true)
        check("the clipboard changed: close", hand(false, true, words), false)
        check("not a field: close", hand(true, false, words), false)
        check("the app will not say: close", hand(true, true, nil), false)
        check("other words before the caret: close", hand(true, true, "Ship it on Monday."), false)

        print("The words before the caret")
        func ends(_ before: String, _ pasted: String) -> Bool {
            Destination.endsAtCaret(before, with: pasted)
        }
        check("exactly the words", ends(words, words), true)
        check("text before them in the field", ends("Hi team. " + words, words), true)
        check("the field has CRLF, the clipboard LF",
              ends("Notes:\r\nfirst\r\nsecond", "first\nsecond"), true)
        check("the field has LF, the clipboard CRLF",
              ends("Notes:\nfirst\nsecond", "first\r\nsecond"), true)
        check("the field has CR alone", ends("first\rsecond", "first\nsecond"), true)
        // Measured in a Chrome contenteditable with two paragraphs.
        check("a web composer drops the break between blocks",
              ends("Hi team.Ship it on Friday.", "Hi team.\nShip it on Friday."), true)
        check("dropping breaks still needs the same words",
              ends("Hi team.Ship it on Monday.", "Hi team.\nShip it on Friday."), false)
        check("the caret is not at their end", ends(words + " And more", words), false)
        check("only part of them", ends("on Friday.", words), false)
        check("nothing was pasted", ends(words, ""), false)

        print(failures == 0 ? "\(total)/\(total)" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
