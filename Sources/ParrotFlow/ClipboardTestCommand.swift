import AppKit

/// `--clipboard-test` — checks when this app may write to the clipboard, and
/// what it writes, against the real `NSPasteboard`.
///
/// Both rules are arithmetic on `NSPasteboard.changeCount`, and both were wrong
/// in a way that only showed up as lost work. An in-place edit that Slack
/// refuses falls back to leaving the rewrite on the clipboard, and the ladder it
/// just came down pastes, so the count has moved and this app is what moved it:
/// the fallback used to read that as "the user copied something" and drop the
/// rewrite. The repair for that then walks into the second rule, because the
/// paste has a restore queued behind it that would put the pre-paste contents
/// straight back over the rewrite.
///
/// A real pasteboard rather than a fake one. What is being tested is which
/// writes move the count and by how much — `clearContents` does, `setString`
/// does not — and a fake that answers that question is a restatement of the
/// assumption rather than a check on it.
///
/// The user's own clipboard is put back at the end.
enum ClipboardTestCommand {

    static func run() -> Int32 {
        let pasteboard = NSPasteboard.general
        // Handed back at the end, every item of it.
        //
        // Not `TextInserter.snapshot`, which keeps the first item and drops the
        // rest. That is a fair trade where it lives: it runs because you asked
        // for a dictation, and it is putting back what its own paste borrowed.
        // Here nothing was asked for — this is a check script — and copying
        // four files in Finder is four items, so the same trade would take
        // three of them without saying so.
        let usersOwn = everything(on: pasteboard)
        defer { putEverythingBack(usersOwn, to: pasteboard) }

        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print("\(passed ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !passed { failures += 1 }
        }

        // An untouched clipboard is writable. The case that always worked.
        write("what the user copied", to: pasteboard)
        let chosen = pasteboard.changeCount
        check("untouched since you chose", TextInserter.clipboardIsOurs(unchangedFrom: chosen))

        // Somebody else copied. The case the rule exists for.
        write("something the user copied while the model was thinking", to: pasteboard)
        check("refused after somebody else copies",
              !TextInserter.clipboardIsOurs(unchangedFrom: chosen))

        // The ladder borrowed the clipboard to paste with, and the edit was
        // refused. `.clipboard` moves the count exactly as the paste branch does
        // and stops short of posting ⌘V into whatever window is in front.
        let borrowed = pasteboard.changeCount
        TextInserter.insert("the rewrite the model produced", mode: .clipboard)
        check("writable after our own paste borrowed it",
              TextInserter.clipboardIsOurs(unchangedFrom: borrowed),
              "count \(borrowed) → \(pasteboard.changeCount)")

        // …but only until somebody else copies over the paste.
        write("something the user copied after the paste", to: pasteboard)
        check("refused when somebody copies over our paste",
              !TextInserter.clipboardIsOurs(unchangedFrom: borrowed))

        // The restore, when nothing has happened since the paste: it puts the
        // borrowed clipboard back.
        write("what the user copied", to: pasteboard)
        let before = TextInserter.snapshot(of: pasteboard)
        write("the paste payload", to: pasteboard)
        TextInserter.putBack(before, to: pasteboard, ifStillAt: pasteboard.changeCount)
        check("the restore puts back what the paste borrowed",
              pasteboard.string(forType: .string) == "what the user copied",
              quoted(pasteboard))

        // The restore, when the refused edit has since left the rewrite there.
        // This is the one that costs the rewrite when it is wrong.
        write("what the user copied", to: pasteboard)
        let borrowedAgain = TextInserter.snapshot(of: pasteboard)
        write("the paste payload", to: pasteboard)
        let paste = pasteboard.changeCount
        write("the rewrite, left here by the refused edit", to: pasteboard)
        TextInserter.putBack(borrowedAgain, to: pasteboard, ifStillAt: paste)
        check("the restore leaves a later write alone",
              pasteboard.string(forType: .string) == "the rewrite, left here by the refused edit",
              quoted(pasteboard))

        // What goes on the clipboard, as well as when.
        //
        // Plain text is the floor and there are two ways down to it: an app
        // nobody has measured, and a transcript with no formatting in it. Both
        // must write the text itself rather than a rendering of it — stripping
        // markers that were never there can still move whitespace, and a
        // dictation has to arrive as it left.
        // Underscores, so it is emphasis the speaker never asked for.
        let formatted = "Call __Dana__ about the invoice"
        let flat = "Call Dana about the invoice"

        TextInserter.insert(formatted, mode: .clipboard, paste: .plain)
        check("an unmeasured app gets plain text, verbatim",
              pasteboard.data(forType: .html) == nil
                  && pasteboard.string(forType: .string) == formatted,
              quoted(pasteboard))

        TextInserter.insert(flat, mode: .clipboard, paste: .html)
        check("a transcript with no markup gets plain text, verbatim",
              pasteboard.data(forType: .html) == nil
                  && pasteboard.string(forType: .string) == flat,
              quoted(pasteboard))

        // Ordinary dictation the Markdown parser reads as formatting. Each of
        // these lost characters the speaker said before `isPlain` asked for
        // block structure over more than one line.
        for spoken in [
            "use the __init__ method",
            "call __main__ before __exit__",
            "we need __slots__ on that class",
            "multiply a*b*c and check the result",
            "rate is 3*4*5",
            "1. Draft 2. Review",
        ] {
            TextInserter.insert(spoken, mode: .clipboard, paste: .html)
            check("one line stays one line: \"\(spoken)\"",
                  pasteboard.data(forType: .html) == nil
                      && pasteboard.string(forType: .string) == spoken,
                  quoted(pasteboard))
        }

        // A link on one line, which is what a transform emits deliberately.
        // The whole point of the path: a dictated "PR 123" reaches Slack as a
        // link you can click, not as brackets.
        let link = "[#123](https://github.com/znat/parrotflow/pull/123) is ready"
        TextInserter.insert(link, mode: .clipboard, paste: .html)
        let linkHTML = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        check("a link on one line is a link",
              linkHTML?.contains("href=\"https://github.com/znat/parrotflow/pull/123\"") == true,
              linkHTML ?? "no html")

        // A link whose words are its own URL. Deliberate — the syntax says so —
        // even though the label cannot be told from an autolink.
        let sameLabel = "[https://example.com](https://example.com) is the one"
        TextInserter.insert(sameLabel, mode: .clipboard, paste: .html)
        let sameHTML = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        check("a link labelled with its own URL is still a link",
              sameHTML?.contains("<a href=\"https://example.com\"") == true,
              sameHTML ?? "no html")

        // Emphasis the speaker asked for: "start bold Dana end bold" reaches
        // `punctuation` as **Dana**, which is asterisks and not inside a word.
        TextInserter.insert("call **Dana** about the invoice", mode: .clipboard, paste: .html)
        let boldHTML = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        check("emphasis a speaker asked for is emphasis",
              boldHTML?.contains("<strong>Dana</strong>") == true,
              boldHTML ?? "no html")

        // And a code span, which is what `backticks` emits.
        TextInserter.insert("read `user.name` first", mode: .clipboard, paste: .html)
        let codeHTML = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        check("a code span on one line is code",
              codeHTML?.contains("<code>user.name</code>") == true,
              codeHTML ?? "no html")

        // A bare URL is not deliberate — the parser makes those out of ordinary
        // text, so a sentence that mentions an address stays a sentence.
        TextInserter.insert("see https://example.com/x for details", mode: .clipboard, paste: .html)
        check("a bare URL is left as a sentence",
              pasteboard.data(forType: .html) == nil,
              quoted(pasteboard))

        // And the case the whole path exists for: block structure, over more
        // than one line. The fallback rides along, so an app that takes neither
        // flavour still gets the sentence.
        let list = "Before Friday:\n\n- call **Dana**\n- reconcile the ledger"
        TextInserter.insert(list, mode: .clipboard, paste: .html)
        let listHTML = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        check("a dictated list is written as one",
              listHTML?.contains("<li>call <strong>Dana</strong></li>") == true,
              listHTML ?? "no html")

        TextInserter.insert(flat, mode: .clipboard, paste: .html)
        check("a measured app is not enough on its own",
              pasteboard.data(forType: .html) == nil,
              quoted(pasteboard))

        print(failures == 0 ? "\nall clipboard rules hold" : "\n\(failures) failed")
        return failures == 0 ? 0 : 1
    }

    /// Every item on the clipboard, copied out of it.
    ///
    /// Copied, not referenced: `pasteboardItems` hands back the pasteboard's
    /// own items, and `clearContents` empties them. Reading the data afterwards
    /// gives nil, so a restore built on them puts back nothing.
    private static func everything(on pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func putEverythingBack(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private static func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func quoted(_ pasteboard: NSPasteboard) -> String {
        "clipboard reads \"\(pasteboard.string(forType: .string) ?? "")\""
    }
}
