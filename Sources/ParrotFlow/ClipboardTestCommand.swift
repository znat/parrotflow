import AppKit

/// `--clipboard-test` — checks the two rules that decide whether this app may
/// write to the clipboard, against the real `NSPasteboard`.
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
