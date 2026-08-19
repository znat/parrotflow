import AppKit
import Foundation

/// The release body, drawn as the Markdown it is.
///
/// GitHub sends it as text. release-please writes it with a heading, a bullet
/// per change, and two links on every bullet — the issue and the commit. Shown
/// raw that is more URL than sentence: a ten line release fills the screen and
/// the words are the smallest part of it.
///
/// So it is parsed and drawn. Headings read as headings, bullets as bullets,
/// and a link as the words it was written on, still clickable. The notes then
/// go in a scroll view rather than in the alert's own text, because an alert
/// grows to fit its text and a long release pushed the buttons off the screen.
enum ReleaseNotes {

    // MARK: - Markdown

    /// Bold, italic and code survive the first pass as a bitmask and become
    /// fonts in the second, once the block they landed in has said what size it
    /// is. A heading's bold and a bullet's bold are not the same font.
    private static let traits = NSAttributedString.Key("pf.markdown.traits")
    private static let bold = 1, italic = 2, code = 4

    private static let bodySize: CGFloat = 12

    static func attributed(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(
                string: markdown,
                attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }

        var blocks: [(intent: PresentationIntent?, text: NSMutableAttributedString)] = []
        for run in parsed.runs {
            let piece = inline(String(parsed[run.range].characters), run: run)
            let intent = run.presentationIntent
            if let last = blocks.last, same(last.intent, intent) {
                last.text.append(piece)
            } else {
                blocks.append((intent, NSMutableAttributedString(attributedString: piece)))
            }
        }

        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(rendered(block.text, intent: block.intent, first: index == 0))
        }
        return out
    }

    /// Two runs belong to the same block when the innermost intent they carry
    /// is the same one. Every block the parser finds gets its own identity,
    /// which is the only thing that separates two bullets in a row.
    private static func same(_ a: PresentationIntent?, _ b: PresentationIntent?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.components.first?.identity == b.components.first?.identity
    }

    private static func inline(
        _ text: String, run: AttributedString.Runs.Run
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [:]

        var mask = 0
        if let intent = run.inlinePresentationIntent {
            if intent.contains(.stronglyEmphasized) { mask |= bold }
            if intent.contains(.emphasized) { mask |= italic }
            if intent.contains(.code) { mask |= code }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        if mask != 0 { attributes[traits] = mask }
        if let link = run.link { attributes[.link] = link }

        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func rendered(
        _ text: NSMutableAttributedString, intent: PresentationIntent?, first: Bool
    ) -> NSAttributedString {
        let kinds = intent?.components.map(\.kind) ?? []

        var size = bodySize
        var weight = NSFont.Weight.regular
        var monospaced = false
        var bullet = ""
        var depth = 0

        for kind in kinds {
            switch kind {
            case .header(let level):
                size = level <= 2 ? bodySize + 2 : bodySize + 1
                weight = .semibold
            case .unorderedList, .orderedList:
                depth += 1
            case .codeBlock:
                monospaced = true
            case .blockQuote:
                depth += 1
            default:
                break
            }
        }

        // Intents run innermost first, so a nested item carries its own
        // `listItem` and then its parent's. The first one is this item, and the
        // list that owns it is the first list after it — without that, a bullet
        // inside a numbered list takes the number.
        if let item = kinds.firstIndex(where: isListItem),
           case .listItem(let ordinal) = kinds[item] {
            bullet = isOrdered(kinds[(item + 1)...].first(where: isList)) ? "\(ordinal)." : "•"
        }

        let indent = CGFloat(max(depth, 0)) * 16
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = bullet.isEmpty ? 6 : 2
        style.paragraphSpacingBefore = first ? 0 : (weight == .semibold ? 8 : 0)
        style.lineSpacing = 1
        style.firstLineHeadIndent = indent
        style.headIndent = indent + (bullet.isEmpty ? 0 : 14)
        if !bullet.isEmpty {
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 14)]
        }

        let base =
            monospaced
            ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)

        let out = NSMutableAttributedString()
        if !bullet.isEmpty {
            out.append(NSAttributedString(string: "\(bullet)\t"))
        }
        out.append(text)

        let whole = NSRange(location: 0, length: out.length)
        out.addAttributes([.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: style], range: whole)

        out.enumerateAttribute(traits, in: whole) { value, range, _ in
            guard let mask = value as? Int else { return }
            var font = base
            if mask & code != 0 {
                font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight)
            }
            if mask & bold != 0 {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if mask & italic != 0 {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            out.addAttribute(.font, value: font, range: range)
        }
        out.removeAttribute(traits, range: whole)
        return out
    }

    private static func isListItem(_ kind: PresentationIntent.Kind) -> Bool {
        if case .listItem = kind { return true }
        return false
    }

    private static func isList(_ kind: PresentationIntent.Kind) -> Bool {
        if case .orderedList = kind { return true }
        if case .unorderedList = kind { return true }
        return false
    }

    private static func isOrdered(_ kind: PresentationIntent.Kind?) -> Bool {
        if case .orderedList = kind { return true }
        return false
    }

    // MARK: - The view it goes in

    /// The notes in a scroll view sized to fit them, up to a ceiling.
    ///
    /// Short notes get exactly their own height and no scroller. Long ones stop
    /// at `maxHeight` and scroll, which is the case this exists for: an NSAlert
    /// lays its own text out at whatever height it needs, so a full release
    /// pushed the buttons past the bottom of the screen.
    ///
    /// Wide enough that the buttons sit in one row. NSAlert stacks them the
    /// moment they do not fit its width, and its width is whatever this view
    /// asks for — four buttons need about 680 points between them.
    ///
    /// It draws its own background rather than sitting on the alert's, so the
    /// notes read as a panel of someone else's text inside the dialog and not
    /// as more of the dialog's own words.
    static func scrollingView(
        _ notes: NSAttributedString, width: CGFloat = 700, maxHeight: CGFloat = 360
    ) -> NSScrollView {
        let padding: CGFloat = 10
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: maxHeight))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Fixed values, not `textBackgroundColor` and `separatorColor`: this
        // sits on the panel's own near-black ground, which does not follow the
        // system, and a layer's border colour is resolved once when it is set —
        // before this view has been put in a window with an appearance.
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 1, alpha: 0.05)
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: maxHeight))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: padding, height: padding)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(
            width: width - padding * 2, height: .greatestFiniteMagnitude
        )
        text.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        text.textStorage?.setAttributedString(notes)
        scroll.documentView = text

        // Laid out before it is measured: `usedRect` on an unlaid container
        // answers with the empty rect, which collapses the alert.
        if let container = text.textContainer, let layout = text.layoutManager {
            layout.ensureLayout(for: container)
            let used = ceil(layout.usedRect(for: container).height) + padding * 2
            scroll.frame = NSRect(
                x: 0, y: 0, width: width, height: min(max(used, 60), maxHeight)
            )
        }
        return scroll
    }
}
