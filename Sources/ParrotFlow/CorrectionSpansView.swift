import AppKit
import SwiftUI

/// One editable word.
///
/// AppKit rather than a SwiftUI `TextField`, and the reason is the caret. Half
/// the gestures in this panel are about *where in the word* you are — space
/// splits at the caret, backspace joins only from the start, the arrows cross
/// only from an edge — and SwiftUI will not say. `NSTextField` hands over its
/// field editor, which reports its selection exactly.
struct WordField: NSViewRepresentable {

    typealias NSViewType = NSTextField
    // Spelled out, because the app has a `Context` of its own — the screen
    // capture in Context.swift — and a bare `Context` here resolves to that,
    // which fails conformance in a way the compiler describes as a
    // "non-matching type".
    typealias Wrapped = NSViewRepresentableContext<WordField>

    let text: String
    let isChanged: Bool
    let focused: Bool
    /// Where to put the caret when focus arrives. Nil is the end, which is
    /// where you want it when you have come to a word to change it.
    let caret: Int?

    var onChange: (String) -> Void
    var onJoinBack: () -> Void
    /// Crossed an edge with an arrow. True for the right-hand edge.
    var onEdge: (Bool) -> Void
    var onTab: (Bool) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    static let font = NSFont.systemFont(ofSize: CorrectionMetrics.wordSize, weight: .regular)

    func makeNSView(context: Wrapped) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Wrapped) {
        context.coordinator.owner = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = isChanged ? .white : NSColor.white.withAlphaComponent(0.82)

        guard focused else { return }
        guard let window = field.window else { return }
        let editing = window.firstResponder === field.currentEditor()
        if !editing { window.makeFirstResponder(field) }
        if let editor = field.currentEditor() {
            let at = caret.map { min($0, field.stringValue.count) } ?? field.stringValue.count
            let wanted = NSRange(location: at, length: 0)
            if !editing || editor.selectedRange != wanted, context.coordinator.placeCaret {
                editor.selectedRange = wanted
                context.coordinator.placeCaret = false
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSTextField, context: Wrapped
    ) -> CGSize? {
        let width = (text as NSString)
            .size(withAttributes: [.font: Self.font]).width
        // A caret needs somewhere to stand in an empty word.
        return CGSize(width: max(ceil(width) + 3, 8), height: ceil(Self.font.ascender - Self.font.descender) + 2)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: WordField
        /// Set when the model asked for a caret position, cleared once it has
        /// been honoured — otherwise every redraw drags the caret back and you
        /// cannot move within a word.
        var placeCaret = true

        init(_ owner: WordField) { self.owner = owner }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            owner.onChange(field.stringValue)
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            let range = textView.selectedRange()
            let atStart = range.location == 0 && range.length == 0
            let atEnd = range.location == textView.string.count && range.length == 0

            switch selector {
            case #selector(NSResponder.deleteBackward(_:)):
                guard atStart else { return false }
                placeCaret = true
                owner.onJoinBack()
                return true
            case #selector(NSResponder.moveLeft(_:)):
                guard atStart else { return false }
                placeCaret = true
                owner.onEdge(false)
                return true
            case #selector(NSResponder.moveRight(_:)):
                guard atEnd else { return false }
                placeCaret = true
                owner.onEdge(true)
                return true
            case #selector(NSResponder.insertTab(_:)):
                placeCaret = true
                owner.onTab(true)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                placeCaret = true
                owner.onTab(false)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                owner.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                owner.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Words laid out like a sentence, wrapping at the edge.
///
/// A plain `HStack` would push the panel wider than the screen for anything
/// longer than a phrase, and a `LazyVGrid` gives every word the same column,
/// which is not what a sentence looks like.
struct SentenceFlow: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 20

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + line)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            view.place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
