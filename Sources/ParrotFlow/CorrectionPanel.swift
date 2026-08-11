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
        model.width = CorrectionMetrics.width(fitting: model.spans, room: Self.room())

        if panel == nil { build() }
        resize()
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        panel?.riseIntoView(makeKey: true)

        // Focus again on the next turn of the runloop, and not before. Two
        // things have to be true before a field can show a caret, and neither
        // is true on this turn: there has to be a window to be first responder
        // in, and that window has to be key — a field made first responder in a
        // window that is not key draws no insertion point. `NSApp.activate`
        // only lands on the next turn, so the key status is asked for again
        // there rather than trusted here.
        //
        // The focus itself is unchanged from the one `load` set, so it takes
        // `focusTick` to make it a change SwiftUI redraws for.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
            self.model.focusFirst()
        }
    }

    private func commit() {
        // Twice is possible: Return reaches the confirm button and, when that
        // button is off, the word field's own newline handler. Once the panel
        // is down there is nothing left to save.
        guard panel?.isVisible == true else { return }
        // Nothing to do is nothing to do, whichever key asked. The button says
        // so by being off; this is the same answer for the field's Return.
        guard model.hasChanges else { return }

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
            contentRect: NSRect(x: 0, y: 0, width: model.width, height: 200),
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
        // Grow and shrink with the help disclosure, so opening it does not
        // clip the explanation.
        model.onResize = { [weak self] in self?.resize() }
        self.panel = panel
    }

    private func resize() {
        guard let panel else { return }
        let size = NSSize(
            width: model.width,
            height: CorrectionMetrics.height(model.spans, width: model.width, help: model.help)
        )
        // Grows about its middle. The panel opens in the centre of the screen,
        // and a disclosure that walked it upwards would move the sentence you
        // are reading.
        let old = panel.frame
        let origin = panel.isVisible
            ? NSPoint(x: old.midX - size.width / 2, y: old.midY - size.height / 2)
            : old.origin
        panel.setFrame(
            NSRect(origin: origin, size: size), display: true, animate: panel.isVisible
        )
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }

    private func reposition() {
        guard let panel else { return }
        guard let frame = Self.screen()?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }

    /// The screen the panel will open on: the one the pointer is on, which is
    /// the one you are working on.
    private static func screen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// How wide the panel is allowed to get before it has to wrap.
    private static func room() -> CGFloat {
        let visible = screen()?.visibleFrame.width ?? CorrectionMetrics.minWidth
        return visible - CorrectionMetrics.screenMargin * 2
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

    /// The gap between two spans on a line. `SentenceFlow` is given the same
    /// number, so the wrap counted here is the wrap you get.
    static let spanGap: CGFloat = 7

    /// Narrow enough not to be a slab behind four words, wide enough for the
    /// footer: the confirm button naming three words is 310pt of label before
    /// the key cap, and the status line and Cancel are beside it.
    static let minWidth: CGFloat = 640
    /// Air left either side of the panel on the screen it opens on.
    static let screenMargin: CGFloat = 80
    /// The head, the instruction, the hint row, the disclosure, the footer, and
    /// the panel's own padding. Measured off the built view rather than added up by hand: the
    /// sentence gets whatever is left over, so guessing this low squeezes it
    /// and the words disappear under the fold with nothing to say they have.
    private static let chrome: CGFloat = 210
    /// The explanation, open. Measured the same way.
    private static let helpHeight: CGFloat = 125
    /// The explanation keeps a readable measure whatever the panel does — a
    /// paragraph 1200pt wide is one your eye loses its place in — so its height
    /// is one number rather than a function of the width. About 60 characters.
    static let helpWidth: CGFloat = 380
    /// Set on a leading of 1.6, which is loose for a paragraph you are meant to
    /// read once. SwiftUI counts the extra, not the whole line.
    static let helpLineSpacing: CGFloat = {
        let font = NSFont.systemFont(ofSize: 12.5)
        return 12.5 * 1.6 - NSLayoutManager().defaultLineHeight(for: font)
    }()
    /// Past this the sentence scrolls rather than the panel growing. Three
    /// lines is a long sentence, and already a panel a third of the way down
    /// the screen. A whole paragraph of dictation would otherwise open a panel
    /// taller than the screen it floats over.
    static let maxLines = 3

    /// 21pt in the rounded face the struck line is set in. The words below it
    /// are `WordField.font`, which is not rounded and not the same width.
    static let heardFont: NSFont = {
        let plain = NSFont.systemFont(ofSize: wordSize)
        guard let rounded = plain.fontDescriptor.withDesign(.rounded) else { return plain }
        return NSFont(descriptor: rounded, size: wordSize) ?? plain
    }()

    /// The width that puts the sentence on one line, within what the screen
    /// allows. Past that it wraps, which is what the line count is for.
    static func width(fitting spans: [Span], room: CGFloat) -> CGFloat {
        let wanted = contentWidth(spans) + Parrot.panelPadding * 2
        return min(max(minWidth, wanted), max(minWidth, room))
    }

    /// The whole sentence on one line.
    static func contentWidth(_ spans: [Span]) -> CGFloat {
        guard !spans.isEmpty else { return 0 }
        return spans.reduce(0) { $0 + spanWidth($1) + spanGap } - spanGap
    }

    /// What one span occupies: the wider of the words and the struck line above
    /// them. A name the decoder split takes its width from what was heard.
    static func spanWidth(_ span: Span) -> CGFloat {
        var written = span.value.reduce(0) { $0 + WordField.width(of: $1) }
        written += CGFloat(max(0, span.value.count - 1)) * text(" ", in: WordField.font)
        written += text(span.pre, in: WordField.font) + text(span.post, in: WordField.font)
        let heard = span.showsHeard ? text(span.heardShown, in: heardFont) : 0
        return max(written, heard)
    }

    private static func text(_ string: String, in font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The same greedy wrap `SentenceFlow` does, counted ahead of time. The
    /// panel is sized before it is drawn, and an estimate off by one line is
    /// either a scrollbar on a sentence that fits or a band of nothing.
    static func lines(_ spans: [Span], width: CGFloat) -> Int {
        let available = width - Parrot.panelPadding * 2
        var lines = 1
        var x: CGFloat = 0
        for span in spans {
            let span = spanWidth(span)
            if x > 0, x + span > available {
                lines += 1
                x = 0
            }
            x += span + spanGap
        }
        return lines
    }

    static func height(_ spans: [Span], width: CGFloat, help: Bool) -> CGFloat {
        let shown = max(1, min(maxLines, lines(spans, width: width)))
        // The gap belongs between lines, so the last one does not pay for it.
        return chrome + lineHeight * CGFloat(shown) - lineGap + (help ? helpHeight : 0)
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
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            head

            // The one thing the panel wants from you, right above the words it
            // is about, and larger than the title. The title says which panel
            // this is; this says what to do with it.
            Text("Fix what I misheard.")
                .font(.system(size: 16.5))
                .foregroundStyle(.primary)
                .padding(.top, 2)

            // Scrolls past the cap rather than growing without end. A minute of
            // dictation is a paragraph, and a panel the height of the screen is
            // not a thing you can read a sentence off.
            ScrollView(.vertical) {
                SentenceFlow(
                    spacing: CorrectionMetrics.spanGap, lineSpacing: CorrectionMetrics.lineGap
                ) {
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

            help

            footer
        }
        .padding(Parrot.panelPadding)
        .frame(width: model.width)
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

    /// The name of the window, and nothing asked of you.
    ///
    /// The mark runs the plumage the other way from `PlumageMark` — shortest
    /// bar sky, tallest scarlet — because this panel is read left to right off
    /// a word, not off a pill.
    private var head: some View {
        HStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Self.bars, id: \.height) { bar in
                    Capsule()
                        .fill(bar.colour)
                        .frame(width: 2.5, height: bar.height)
                }
            }
            .frame(height: 11, alignment: .bottom)

            Text("Vocabulary".uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .kerning(11 * 0.085)
                .foregroundStyle(Parrot.sky)

            Spacer(minLength: 0)
        }
    }

    private static let bars: [(height: CGFloat, colour: Color)] = [
        (5, Parrot.sky), (7, Parrot.leaf), (9, Parrot.amber), (11, Parrot.scarlet)
    ]

    /// Three buttons, right to left in the order you are least likely to want
    /// them. No status line: there was one saying "change a word to teach one",
    /// which is the instruction a second time, in grey, in the far corner from
    /// the words it is about.
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 12)

            // The cap advertises ⌘Z; the panel is what handles it. The undo
            // puts back a whole arrangement of spans and the field a keystroke
            // landed in may not exist afterwards, so it cannot live on a field.
            ActionButton(title: "Undo", key: "⌘Z", filled: false,
                         enabled: model.canUndo, quiet: true) { model.undo() }

            ActionButton(title: "Discard", key: "", filled: false, quiet: true) {
                model.onCancel?()
            }
            .keyboardShortcut(.cancelAction)

            // Leaf, the colour of a changed word's bar. The same promise: this
            // is the thing that is going to happen.
            ActionButton(title: confirmTitle, styled: confirmLabel, key: "↩",
                         filled: false, glass: Parrot.leaf,
                         enabled: model.hasChanges) { model.onSubmit?() }
                // Plain Return, because Return already submits from inside a
                // word — there is nowhere in this panel it would insert a line.
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.top, 4)
    }

    /// The one question the panel cannot answer by being looked at: which words
    /// are worth correcting.
    ///
    /// Shut by default and shut again on every appearance. It answers something
    /// you ask once — by the tenth correction, two paragraphs about what
    /// dictation is are in the way of a two-second job.
    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { model.help.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 7))
                        .rotationEffect(.degrees(model.help ? 90 : 0))
                    Text("Not sure what to correct?")
                }
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if model.help { explanation }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Dictation gets ordinary words right. The ones it misses are yours: product names, people, the jargon you work in. Correct one here and ParrotFlow keeps it, so the next dictation hears it right.")
            Text("Leave a word alone if you simply said it badly. There is nothing to learn from that one — say it again.")
        }
        .font(.system(size: 12.5))
        .lineSpacing(CorrectionMetrics.helpLineSpacing)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: CorrectionMetrics.helpWidth, alignment: .leading)
        .padding(.leading, 11)
        // A rule rather than an indent on its own: the paragraphs are an aside
        // about the sentence above them, and the line says so without a heading
        // to say it. An overlay, not a column beside them — in an HStack the
        // shape takes the height of the first paragraph and stops.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.10))
                .frame(width: 1.5)
        }
    }

    /// The button names the words it is about to teach.
    ///
    /// The corrected forms, not what was heard: those are the terms that get
    /// written, and reading them off the button before pressing it is the whole
    /// check. Past three the names would run the button off the panel, so it
    /// counts them instead. With none the sentence stays and the words drop out
    /// of it, so the button does not change shape while you type.
    private var confirmParts: [(text: String, lit: Bool)] {
        let words = model.rules().map(\.corrected)
        var parts: [(String, Bool)] = [("Add", false)]
        if words.count > 3 {
            parts.append((" \(words.count) words", false))
        } else {
            for (index, word) in words.enumerated() {
                // English, not a list: "A and B", "A, B and C".
                parts.append((index == 0 ? " " : (index == words.count - 1 ? " and " : ", "), false))
                parts.append((word, true))
            }
        }
        parts.append((" to the vocabulary", false))
        return parts.map { (text: $0.0, lit: $0.1) }
    }

    private var confirmTitle: String {
        confirmParts.map(\.text).joined()
    }

    /// The same sentence with the words themselves lit. They are the thing to
    /// check before pressing it, so they are the part that is not dimmed.
    private var confirmLabel: Text {
        confirmParts.reduce(Text("")) { label, part in
            label + (part.lit
                ? Text(part.text).bold().foregroundStyle(Color.white)
                : Text(part.text).foregroundStyle(ActionButton.glassText))
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
            Text(span.showsHeard ? span.heardShown : " ")
                .font(.system(size: CorrectionMetrics.wordSize, design: .rounded))
                .foregroundStyle(.tertiary)
                .strikethrough(span.showsHeard, color: .white.opacity(0.22))
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
            tick: model.focusTick,
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
