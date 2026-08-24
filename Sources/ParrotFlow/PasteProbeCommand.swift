import AppKit
import Foundation

/// `--paste-probe` — puts one known formatted document on the clipboard in a
/// chosen set of flavours, so you can paste it by hand and see what the target
/// app does.
///
/// The question is which pasteboard flavour each app accepts, and nothing in
/// this repository can answer it. A pasteboard item can carry `public.html`,
/// `public.rtf` and plain text at once, and the receiving app picks. Slack,
/// Outlook and a browser compose box each pick differently and each lose
/// something different.
///
/// It renders through `Markup`, which is what `TextInserter` writes with. One
/// registry, two callers: what you score here is what the app will get.
///
/// `all` first — it is the shape a shipping paste has, and an app that keeps
/// everything under it is finished. A single flavour is the follow-up, for an
/// app that scored badly, to find out which one to withhold.
///
/// Your clipboard is not put back. The payload has to survive for you to paste.
enum PasteProbeCommand {

    /// Seven things worth scoring, in one paste. Everything here is a feature
    /// that some app somewhere drops: nesting flattens, ordered lists lose
    /// their numbers, a link keeps its words and loses its URL.
    private static let fixture = """
        Ship the **billing fix** before Friday. Keep it *quiet* until it lands.

        - Call [Dana](https://example.com/dana) about the July invoice
        - Reconcile the ledger
          - the July rows first
          - then August
        - Run `make reconcile` and post the diff

        1. Draft
        2. Review
        3. Ship
        """

    private static let usage =
        "usage: ParrotFlow --paste-probe <plain|markdown|html|rtf|all>"
        + " [--file <fixture.md>] [--bare] [--show]"

    static func run(flavour: String, file: String?, bare: Bool, show: Bool) -> Int32 {
        let markdown: String
        if let file {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                print("✗ cannot read \(file)")
                return 2
            }
            markdown = text
        } else {
            markdown = fixture
        }

        let chosen: [Markup.Flavour]
        switch flavour {
        case "all": chosen = [.html, .rtf]
        default:
            guard let one = Markup.Flavour[flavour] else {
                print(usage)
                return 2
            }
            chosen = [one]
        }

        let markup = Markup.parse(markdown)
        let item = markup.item(chosen, fallback: !bare)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        print("flavour   \(flavour)\(bare ? " --bare" : "")")
        // Every type, including the `utf16-external-plain-text` AppKit adds
        // behind a string. It is on the clipboard, so it is in the listing.
        let width = item.types.map(\.rawValue.count).max() ?? 0
        for type in item.types {
            let bytes = item.data(forType: type)?.count ?? 0
            let name = type.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0)
            print("wrote     \(name)\(bytes) bytes")
        }
        print("clipboard the fixture is on it now; what you had is gone")
        if !item.types.contains(.string) {
            print("          no plain text — a clipboard manager will read this as empty")
        }
        print("")
        print("Paste with ⌘V and score seven things:")
        print("  bold · italic · code · bullet · nested bullet · numbered list · link")
        print("A link is two scores: the words it was written on, and the URL behind them.")

        if show {
            print("\n--- markdown ---\n\(markup.source)")
            print("\n--- plain ---\n\(markup.plain)")
            print("\n--- html ---\n\(markup.html)")
        }
        return 0
    }
}
