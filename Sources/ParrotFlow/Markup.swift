import AppKit
import Foundation

/// A dictation that carries formatting, parsed once and rendered as many ways
/// as the app in front of it will take.
///
/// Markdown is the wire format, and that is the decision the rest of this
/// rests on. Every stage in the pipeline is a string in and a string out, so a
/// transform that adds bullets is a transform that returns different text and
/// nothing else has to learn a new type. Anything richer would have to be
/// converted at each boundary or understood by every stage.
///
/// Parsed at the end, on the way to the pasteboard, and only when there is
/// something to parse — see `isPlain`.
struct Markup {

    /// The Markdown exactly as it arrived. What `markdown` renders, and what a
    /// transcript with no formatting in it must come back as, byte for byte.
    let source: String

    private let blocks: [Block]

    static func parse(_ markdown: String) -> Markup {
        Markup(source: markdown, blocks: Self.blocks(of: markdown))
    }

    /// True when this has to be written as the text itself rather than as
    /// markup. The gate on the whole path, and deliberately hard to leave.
    ///
    /// Asking "does this parse as Markdown" is the wrong question, because
    /// ordinary dictation does. Measured on plain sentences:
    ///
    ///     use the __init__ method   ->  use the <strong>init</strong> method
    ///     multiply a*b*c            ->  multiply a<em>b</em>c
    ///     1. Draft 2. Review        ->  <ol><li>Draft 2. Review</li></ol>
    ///
    /// Each one loses characters the speaker said, and `__init__` is a word a
    /// developer dictates. So inline emphasis alone never counts. What counts
    /// is block structure — a list, a heading, a code block, a quote — spread
    /// over more than one line. A transform that formats deliberately produces
    /// that; a single dictated sentence cannot produce it by accident.
    ///
    /// The real gate is a stage saying its output is Markdown, which none does
    /// yet. This is the conservative half of that: refusing wrongly costs a
    /// bold, letting through wrongly costs the characters.
    var isPlain: Bool {
        guard source.contains("\n") else { return true }
        return !blocks.contains { block in
            !Self.containers(block.kinds).isEmpty
                || Self.marker(block.kinds) != nil
                || Self.headerLevel(block.kinds) != nil
                || Self.isCodeBlock(block.kinds)
        }
    }

    // MARK: - Flavours

    /// One pasteboard flavour: what it is called, which type it claims, and how
    /// to render it.
    ///
    /// A registry rather than a switch, because two callers read it — the
    /// probe that measures an app and the inserter that writes to it. A switch
    /// in each is how you end up measuring one thing and shipping another.
    struct Flavour {
        let name: String
        let type: NSPasteboard.PasteboardType
        let render: (Markup) -> Data?

        static let plain = Flavour(name: "plain", type: .string) { Data($0.plain.utf8) }
        static let markdown = Flavour(name: "markdown", type: .string) { Data($0.source.utf8) }
        static let html = Flavour(name: "html", type: .html) { Data($0.html.utf8) }
        static let rtf = Flavour(name: "rtf", type: .rtf) { $0.richText() }

        static let all: [Flavour] = [.plain, .markdown, .html, .rtf]

        static subscript(name: String) -> Flavour? {
            all.first { $0.name == name }
        }
    }

    /// The item to put on the pasteboard.
    ///
    /// Plain text always rides along, because a rich flavour on its own is not
    /// a shape anything puts on a real clipboard: a clipboard manager reads it
    /// as empty, and a paste that lands as plain cannot be told from a paste
    /// that did not land. `fallback: false` withholds it, which is a diagnostic
    /// — `--paste-probe --bare` — and never a setting.
    ///
    /// A flavour that will not render is dropped and the rest still go. Losing
    /// one costs the bold; there is no failure here worth losing the sentence
    /// over.
    func item(_ flavours: [Flavour], fallback: Bool = true) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        var claimed: Set<NSPasteboard.PasteboardType> = []

        for flavour in flavours {
            guard !claimed.contains(flavour.type) else { continue }
            guard let data = flavour.render(self) else {
                Log.write("paste: \(flavour.name) would not render; dropped")
                continue
            }
            item.setData(data, forType: flavour.type)
            claimed.insert(flavour.type)
        }

        // `markdown` claims the plain-text type itself, and then there is no
        // fallback left to add.
        if fallback, !claimed.contains(.string) {
            item.setString(plain, forType: .string)
        }
        return item
    }

    // MARK: - Rendering

    var html: String {
        var out = ""
        var lists: [(tag: String, identity: Int, itemOpen: Bool)] = []

        func close(to depth: Int) {
            while lists.count > depth {
                let level = lists.removeLast()
                if level.itemOpen { out += "</li>" }
                out += "</\(level.tag)>"
            }
        }

        for block in blocks {
            let path = Self.containers(block.kinds)
            var common = 0
            while common < min(path.count, lists.count),
                lists[common].identity == path[common].identity {
                common += 1
            }
            close(to: common)
            for level in path[common...] {
                out += "<\(level.tag)>"
                lists.append((level.tag, level.identity, false))
            }

            let inner = Self.inline(block.pieces)
            if Self.marker(block.kinds) != nil, !lists.isEmpty {
                // A nested list opens inside its parent item, so the item is
                // left open until a sibling or the close needs it shut.
                if lists[lists.count - 1].itemOpen { out += "</li>" }
                out += "<li>\(inner)"
                lists[lists.count - 1].itemOpen = true
            } else if let level = Self.headerLevel(block.kinds) {
                out += "<h\(level)>\(inner)</h\(level)>"
            } else if Self.isCodeBlock(block.kinds) {
                out += "<pre><code>\(inner)</code></pre>"
            } else {
                out += "<p>\(inner)</p>"
            }
        }
        close(to: 0)
        return out
    }

    /// The best plain text this document can be: markers gone, bullets kept,
    /// and a link's URL in brackets after the words it was written on.
    ///
    /// The URL is kept rather than dropped. It is the fallback every paste
    /// carries, and a fallback that silently loses the address is worse than a
    /// visible one.
    var plain: String {
        var lines: [String] = []
        var previousRoot: Int?
        var started = false

        for block in blocks {
            let text = block.pieces.map { piece -> String in
                guard let link = piece.link else { return piece.text }
                let url = link.absoluteString
                return piece.text == url ? piece.text : "\(piece.text) (\(url))"
            }.joined()

            // A blank line between two blocks that are not items of the same
            // list. Without the root check two lists in a row run together.
            let path = Self.containers(block.kinds)
            let root = path.first?.identity
            if started, root == nil || root != previousRoot { lines.append("") }
            started = true
            previousRoot = root

            if !path.isEmpty, let bullet = Self.marker(block.kinds) {
                lines.append(String(repeating: "  ", count: path.count - 1) + bullet + " " + text)
            } else {
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// RTF by way of the HTML, not from the Markdown a second time.
    ///
    /// AppKit's HTML importer writes a real `\listtable` and real `HYPERLINK`
    /// fields, which attributed text built by hand does not. Going through it
    /// also keeps the two rich flavours the same document, so a difference in
    /// the target app is the target app. It needs no `NSApplication`, so it
    /// runs in a command as happily as in the app.
    ///
    /// Measured on the fixture: 637ms the first time in a process, then 2ms.
    /// The cost is WebKit starting, not the document. Nothing reaches this yet
    /// — no app is `.rtf` — but the first formatted paste of a session into one
    /// would pay it, and the fix would be to import a byte of HTML at launch.
    func richText() -> Data? {
        guard
            let document = try? NSAttributedString(
                data: Data(html.utf8),
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            )
        else { return nil }
        return document.rtf(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [:]
        )
    }

    private static func inline(_ pieces: [Piece]) -> String {
        pieces.map { piece in
            var text = escaped(piece.text)
            if piece.code { text = "<code>\(text)</code>" }
            if piece.bold { text = "<strong>\(text)</strong>" }
            if piece.italic { text = "<em>\(text)</em>" }
            if piece.struck { text = "<s>\(text)</s>" }
            if let link = piece.link {
                text = "<a href=\"\(escaped(link.absoluteString))\">\(text)</a>"
            }
            return text
        }.joined()
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - The Markdown, in blocks

    private struct Piece {
        let text: String
        let bold: Bool
        let italic: Bool
        let code: Bool
        let struck: Bool
        let link: URL?
    }

    private struct Block {
        let kinds: [PresentationIntent.IntentType]
        var pieces: [Piece]
    }

    private static func blocks(of markdown: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            let piece = Piece(
                text: markdown, bold: false, italic: false, code: false, struck: false, link: nil
            )
            return [Block(kinds: [], pieces: [piece])]
        }

        var blocks: [Block] = []
        for run in parsed.runs {
            let inline = run.inlinePresentationIntent ?? []
            let piece = Piece(
                text: String(parsed[run.range].characters),
                bold: inline.contains(.stronglyEmphasized),
                italic: inline.contains(.emphasized),
                code: inline.contains(.code),
                struck: inline.contains(.strikethrough),
                link: run.link
            )
            let kinds = run.presentationIntent?.components ?? []
            // Every block the parser finds gets its own identity, and the
            // innermost one is this block's. It is the only thing that
            // separates two bullets in a row.
            if !blocks.isEmpty, blocks.last?.kinds.first?.identity == kinds.first?.identity {
                blocks[blocks.count - 1].pieces.append(piece)
            } else {
                blocks.append(Block(kinds: kinds, pieces: [piece]))
            }
        }
        return blocks
    }

    /// The lists and quotes a block sits inside, outermost first. Intents
    /// arrive innermost first, which is the wrong end to open tags from.
    private static func containers(
        _ kinds: [PresentationIntent.IntentType]
    ) -> [(tag: String, identity: Int)] {
        kinds.reversed().compactMap { component -> (tag: String, identity: Int)? in
            switch component.kind {
            case .unorderedList: return ("ul", component.identity)
            case .orderedList: return ("ol", component.identity)
            case .blockQuote: return ("blockquote", component.identity)
            default: return nil
            }
        }
    }

    /// The bullet or the number, or nil when this block is not a list item.
    ///
    /// The list that owns an item is the first list after it, not the first
    /// list in the array — otherwise a bullet nested in a numbered list takes
    /// the number.
    private static func marker(_ kinds: [PresentationIntent.IntentType]) -> String? {
        guard
            let item = kinds.firstIndex(where: {
                if case .listItem = $0.kind { return true }
                return false
            }),
            case .listItem(let ordinal) = kinds[item].kind
        else { return nil }

        let owner = kinds[(item + 1)...].first {
            switch $0.kind {
            case .orderedList, .unorderedList: return true
            default: return false
            }
        }
        if case .orderedList = owner?.kind { return "\(ordinal)." }
        return "•"
    }

    private static func headerLevel(_ kinds: [PresentationIntent.IntentType]) -> Int? {
        for component in kinds {
            if case .header(let level) = component.kind { return min(max(level, 1), 6) }
        }
        return nil
    }

    private static func isCodeBlock(_ kinds: [PresentationIntent.IntentType]) -> Bool {
        kinds.contains {
            if case .codeBlock = $0.kind { return true }
            return false
        }
    }
}
