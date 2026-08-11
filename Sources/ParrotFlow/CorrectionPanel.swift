import AppKit
import SwiftUI

/// Teach me the words I got wrong.
///
/// The sentence you just dictated, editable in place. What was heard sits above
/// the word it became, struck through; the bar under each word carries its
/// state; and a rule is keyed on a **span** rather than on a word — see
/// `Span` for why that is the whole point.
///
/// Four gestures, and every one of them is a gesture a text field already has:
/// type over a word, `space` to split one into two, `⌫` at the start to join a
/// word to the one before, and clear a word to remove it. `⌘Z` undoes. There is
/// deliberately nothing of its own to learn — an earlier pass had "click a
/// struck word to release it", and needing a sentence to explain it was the
/// argument against it.
///
/// Visually a sibling of the pill: near-black at 95%, the same plumage rim.
final class CorrectionPanel {

    private var panel: KeyPanel?
    private let model = SpansModel()

    /// (rules to save, the full corrected text to put back).
    var onSave: (([(heard: String, corrected: String)], String) -> Void)?
    var onCancel: (() -> Void)?

    func show(selection: String) {
        model.load(sentence: selection)
        present()
    }

    /// Opens with the rules already filled in — the model proposed them, you
    /// confirm them. Written as a sentence of its own, because the panel now
    /// edits a sentence rather than a table of pairs.
    func show(rules: [(heard: String, corrected: String)]) {
        model.load(rules: rules)
        present()
    }

    private func present() {
        model.onSubmit = { [weak self] in self?.commit() }
        model.onCancel = { [weak self] in self?.dismiss(cancelled: true) }

        if panel == nil { build() }
        resize()
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        panel?.riseIntoView(makeKey: true)
    }

    private func commit() {
        let rules = model.rules()
        let corrected = model.sentence()
        dismiss(cancelled: false)
        onSave?(rules, corrected)
    }

    private func dismiss(cancelled: Bool) {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        if cancelled { onCancel?() }
    }

    private func build() {
        let hosting = NSHostingView(rootView: CorrectionView().environmentObject(model))
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: CorrectionMetrics.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.adoptParrotAppearance()
        panel.onCancel = { [weak self] in self?.dismiss(cancelled: true) }
        panel.onUndo = { [weak self] in self?.model.undo() }
        self.panel = panel
    }

    private func resize() {
        guard let panel else { return }
        let height = CorrectionMetrics.height(forWords: model.spans.count)
        panel.setContentSize(NSSize(width: CorrectionMetrics.width, height: height))
        panel.contentView?.frame = NSRect(
            x: 0, y: 0, width: CorrectionMetrics.width, height: height
        )
    }

    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }
}

enum CorrectionMetrics {

    /// The size the sentence is set in, and the size the struck line above it
    /// is set in too. They are the same sentence said twice — one of them set
    /// small read as a footnote about the other.
    static let wordSize: CGFloat = 21
    /// The struck line, the word, and the bar under it. Both lines of text are
    /// 21pt now, so this is close to twice what the first pass reserved.
    static let spanHeight: CGFloat = 62
    /// Air between one line of the sentence and the next.
    static let lineGap: CGFloat = 16
    static let lineHeight: CGFloat = spanHeight + lineGap

    static let width: CGFloat = 700
    /// Header, the hint row, the footer, and the panel's own padding. Measured
    /// off the built view rather than added up by hand: the sentence gets
    /// whatever is left over, so guessing this low squeezes it and the words
    /// disappear under the fold with nothing to say they have.
    private static let chrome: CGFloat = 159
    /// Past this the sentence scrolls rather than the panel growing. Three
    /// lines is about thirty words — a long sentence, and already a panel a
    /// third of the way down the screen. A whole paragraph of dictation would
    /// otherwise open a panel taller than the screen it floats over.
    static let maxLines = 3
    /// What one word costs across the line, spacing included. Measured off the
    /// panel at 21pt: ordinary dictation fits twelve or thirteen words to a
    /// line at this width, and this is a little under that. Being wrong is
    /// cheap either way — too few lines and the sentence scrolls, too many and
    /// there is air under it.
    private static let wordWidth: CGFloat = 56

    private static func lines(forWords words: Int) -> Int {
        let perLine = max(1, Int((width - Parrot.panelPadding * 2) / wordWidth))
        return max(1, min(maxLines, (words + perLine - 1) / perLine))
    }

    static func height(forWords words: Int) -> CGFloat {
        // The gap belongs between lines, so the last one does not pay for it.
        chrome + lineHeight * CGFloat(lines(forWords: words)) - lineGap
    }
}

/// Borderless panels refuse key status, which would leave every field unable
/// to take a keystroke.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// ⌘Z here rather than on the field, because the undo is the panel's: it
    /// puts back a whole arrangement of spans, and the field a keystroke landed
    /// in may not exist afterwards.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            onUndo?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - View

struct CorrectionView: View {
    @EnvironmentObject private var model: SpansModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "Vocabulary", note: "teach me the words I got wrong")

            // Scrolls past the cap rather than growing without end. A minute of
            // dictation is a paragraph, and a panel the height of the screen is
            // not a thing you can read a sentence off.
            ScrollView(.vertical) {
                SentenceFlow(spacing: 7, lineSpacing: CorrectionMetrics.lineGap) {
                    ForEach(model.spans) { span in
                        SpanView(span: span)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: CorrectionMetrics.lineHeight
                * CGFloat(CorrectionMetrics.maxLines) - CorrectionMetrics.lineGap)
            .padding(.top, 8)

            // Laid out whether it shows or not. It arrives on the first edit,
            // the panel is sized once when it opens, and a row appearing under
            // the sentence would push the buttons off the bottom.
            hint.opacity(model.hasEdited ? 1 : 0)

            PanelActions(
                status: summary,
                cancelTitle: "Cancel",
                confirmTitle: confirmTitle,
                // The hint row above holds its space whether it shows or not,
                // so the standing 24pt over the buttons would sit on top of a
                // band of nothing.
                compact: true,
                onCancel: { model.onCancel?() },
                onConfirm: { model.onSubmit?() }
            )
        }
        .padding(Parrot.panelPadding)
        .frame(width: CorrectionMetrics.width)
        .parrotSurface(
            RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
            solid: true
        )
        .onExitCommand { model.onCancel?() }
    }

    /// Only the two you could not guess. Clearing a field to empty is what
    /// clearing a field does everywhere, and ⌘Z is on the button below.
    private var hint: some View {
        HStack(spacing: 14) {
            key("space", "splits a word in two")
            key("⌫", "at the start joins it to the word before")
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(.tertiary)
    }

    private func key(_ cap: String, _ said: String) -> some View {
        HStack(spacing: 5) {
            Text(cap)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                }
            Text(said)
        }
    }

    private var summary: String {
        switch model.rules().count {
        case 0: return "Change a word to teach one"
        case 1: return "1 word → vocabulary"
        case let count: return "\(count) words → vocabulary"
        }
    }

    /// The button names the words it is about to teach.
    ///
    /// The corrected forms, not what was heard: those are the terms that get
    /// written to the vocabulary, and reading them off the button before
    /// pressing it is the whole check. Past three the names would run the
    /// button into the status line, so it counts them instead. With nothing
    /// changed there is nothing to name, and the status line to the left
    /// already says what to do about that.
    private var confirmTitle: String {
        let words = model.rules().map(\.corrected)
        switch words.count {
        case 0: return "Save"
        case 1...3: return "Add \(words.joined(separator: ", ")) to the vocabulary"
        default: return "Add \(words.count) words to the vocabulary"
        }
    }
}

/// One span: what was heard above, what it became below, and the bar that says
/// which is which.
private struct SpanView: View {
    @EnvironmentObject private var model: SpansModel
    let span: Span

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Absolutely nothing moves when this appears — it is laid out in
            // the space the flow already reserved above every word, so a word
            // changing never shifts the line it is in.
            //
            // Set at the size of the word below it. Small, it read as a
            // footnote about the word; the same size, the two lines read as one
            // sentence rewritten over another.
            Text(span.isChanged || span.heard.count > 1 ? span.heardShown : " ")
                .font(.system(size: CorrectionMetrics.wordSize, design: .rounded))
                .foregroundStyle(.tertiary)
                .strikethrough(span.isChanged || span.heard.count > 1, color: .white.opacity(0.22))
                .lineLimit(1)
                .fixedSize()

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !span.pre.isEmpty { punctuation(span.pre) }
                ForEach(Array(span.value.enumerated()), id: \.offset) { at, word in
                    if at > 0 { punctuation(" ") }
                    field(word, at: at)
                }
                if !span.post.isEmpty { punctuation(span.post) }
            }

            // The whole state display. Faint is untouched, sky is where you
            // are, leaf is what will change — and it runs unbroken under a
            // multi-word span, which is how "these are one thing you said" is
            // said without adding anything.
            RoundedRectangle(cornerRadius: 1)
                .fill(bar)
                .frame(height: 1.5)
        }
        .fixedSize()
    }

    private var isHere: Bool { model.focus?.span == span.id }

    private var bar: Color {
        if span.isChanged { return Parrot.leaf }
        if isHere { return Parrot.sky }
        return Color.white.opacity(0.13)
    }

    private func punctuation(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CorrectionMetrics.wordSize))
            .foregroundStyle(.secondary)
    }

    private func field(_ word: String, at: Int) -> some View {
        WordField(
            text: word,
            isChanged: span.isChanged,
            focused: model.focus?.span == span.id && model.focus?.word == at,
            caret: model.focus?.at,
            onChange: { model.typed($0, span: span.id, word: at) },
            onJoinBack: { model.joinBack(span: span.id, word: at) },
            onEdge: { forward in
                model.step(from: span.id, word: at, forward: forward, keepingEdge: true)
            },
            onTab: { forward in
                model.step(from: span.id, word: at, forward: forward, keepingEdge: false)
            },
            onSubmit: { model.onSubmit?() },
            onCancel: { model.onCancel?() }
        )
        .onTapGesture { model.focus = SpanCaret(span: span.id, word: at, at: nil) }
    }
}
