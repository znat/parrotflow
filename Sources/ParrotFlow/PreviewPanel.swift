import AppKit
import SwiftUI

/// Shows what a prompt produced, before it replaces anything.
///
/// A transform overwrites text you selected, and it is triggered by voice —
/// there is no dialog in the way and no dictation-shaped undo afterwards. So
/// the default is to propose rather than apply, the same bargain the correction
/// panel makes.
///
/// The result is editable. A confirm that only offers yes or no is worth little
/// when the model got it nearly right: discarding costs you the whole rewrite
/// over one word, and applying costs you the word. Fixing it here costs
/// neither.
final class PreviewPanel {

    private var panel: PreviewKeyPanel?
    private let model = PreviewModel()

    /// The text as it stands when the user accepts it, edits included.
    var onApply: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// The whole dictation, editable, so a misheard sentence can be fixed
    /// where it landed. Opened by the offer the pill makes after a dictation.
    func show(transcript: String) {
        model.loadTranscript(transcript)
        present()
    }

    func show(prompt: String, before: String, after: String) {
        model.load(prompt: prompt, before: before, after: after)
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

    var isVisible: Bool { panel?.isVisible ?? false }

    private func commit() {
        let text = model.after
        dismiss(cancelled: false)
        onApply?(text)
    }

    /// Escape has two ways in — the button that advertises it and the panel's
    /// own `cancelOperation` — and only the first of them should be answered.
    private func dismiss(cancelled: Bool) {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        if cancelled { onCancel?() }
    }

    private func build() {
        let hosting = NSHostingView(rootView: PreviewView().environmentObject(model))
        hosting.frame = NSRect(x: 0, y: 0, width: PreviewMetrics.minimumWidth, height: 260)
        hosting.autoresizingMask = [.width, .height]

        let panel = PreviewKeyPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Same glass as the pill, and inset by the same kind of margin — the
        // glow needs somewhere to land, and the frost must not fill it.
        panel.contentView = ParrotGlass.container(
            hosting, radius: Parrot.panelRadius, inset: PreviewMetrics.bleed,
            // Heavier than the pill's: this holds a sentence you read word by
            // word and select inside, and it has to stay legible over whatever
            // happens to be behind it.
            // Liquid Glass handles legibility itself, so this is a nudge rather
            // than the scrim it replaced.
            tint: NSColor.black.withAlphaComponent(0.20)
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Drawn in SwiftUI instead: the window shadow traces the window's
        // alpha, so with a glow bleeding into the margin it would outline the
        // blur rather than the panel.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.adoptParrotAppearance()
        panel.onCancel = { [weak self] in self?.dismiss(cancelled: true) }
        self.panel = panel
    }

    /// Grows with the longer of the two texts, up to a cap.
    private func resize() {
        guard let panel else { return }
        let width = PreviewMetrics.width(for: model.after)
        let height = PreviewMetrics.height(
            for: model.after, singleLine: model.singleLine, transcript: model.isTranscript
        )
        panel.setContentSize(NSSize(width: width, height: height))
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

enum PreviewMetrics {
    /// The narrowest the panel gets.
    ///
    /// Small, because the panel is now sized by what you said and a short
    /// correction is short. At 840 — the old fixed width — "Okay." arrived in a
    /// panel built for a paragraph, and the emptiness read as a layout that had
    /// not finished loading. Wide enough for the buttons and an eyebrow, and
    /// nothing beyond that is reserved.
    static let minimumWidth: CGFloat = 420
    private static let maximumBody: CGFloat = 340

    /// Transparent margin for the glow to land in — same idea as the pill's.
    /// See `PlumageBloom`.
    static let bleed: CGFloat = 40

    /// The size the sentence is set in — the whole point of the panel is to
    /// read it back and put a caret in the middle of a word without aiming.
    static let fontSize: CGFloat = 30

    /// Everything either side of the text on one line. Just the panel's own
    /// padding now that the field has no box, plus a little slack so the last
    /// character is not against the edge.
    private static let sideChrome: CGFloat = Parrot.panelPadding * 2 + 14

    /// How wide the sentence actually is, measured rather than counted.
    ///
    /// Character counts were the first try and they cannot work here: "MMM" and
    /// "iii" are the same count and nowhere near the same width, and the whole
    /// decision below — one line or an area — turns on which side of the panel
    /// edge the last word falls.
    static func textWidth(_ text: String) -> CGFloat {
        (text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)])
            .width
    }

    /// As wide as the sentence needs, between the minimum and what the screen
    /// will take. The bleed is on top of both — it is window, not panel.
    ///
    /// It grows because the alternative is wrapping a sentence that would have
    /// fitted, and a wrapped sentence is one you read twice. It stops because a
    /// panel wider than the screen is not a panel.
    static func width(for text: String) -> CGFloat {
        min(max(minimumWidth, textWidth(text) + sideChrome), ceiling) + bleed * 2
    }

    /// The old fixed width, kept for the sheet: it draws one sample and the
    /// sample should be a normal-looking panel rather than the narrowest one.
    static let sampleWidth: CGFloat = 840

    /// Nothing wider than the screen it appears on, less a margin so it still
    /// reads as a panel floating over something.
    static var ceiling: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return minimumWidth }
        return max(minimumWidth, visible.width - 160 - bleed * 2)
    }

    /// One line means one field: a text area for a sentence that fits on a line
    /// is a box with an acre of nothing under it, and a caret you have to aim
    /// at. It fits when the panel is allowed to be wide enough to hold it.
    static func singleLine(_ text: String) -> Bool {
        !text.contains("\n") && textWidth(text) + sideChrome <= ceiling
    }

    /// Panel chrome, by which half of the panel it is.
    ///
    /// The dictation panel has no header and no status line — it has one title
    /// above the field instead — so reserving room for a header it does not
    /// draw is exactly the gap between the field and the buttons that made it
    /// look unbalanced.
    private static func chrome(transcript: Bool) -> CGFloat {
        let padding = Parrot.panelPadding * 2
        // The gap above the buttons, and the buttons.
        let actions: CGFloat = transcript ? 10 + 28 : 24 + 28
        // An eyebrow and its gap, or the struck-through original and its gap.
        let title: CGFloat = transcript ? 13 + 10 : 21 + 10
        return padding + actions + title
    }

    static func height(for text: String, singleLine: Bool, transcript: Bool = false) -> CGFloat {
        let field = singleLine
            ? fontSize + 6 + 1
            : min(maximumBody, max(104, CGFloat(lines(text)) * (fontSize + 8) + 20))
        return chrome(transcript: transcript) + field + bleed * 2
    }

    private static func lines(_ text: String) -> Int {
        let perLine = max(1, minimumWidth - sideChrome)
        return max(2, Int(ceil(textWidth(text) / perLine)))
    }
}

private final class PreviewKeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Model

final class PreviewModel: ObservableObject {
    @Published var prompt: String = ""
    @Published var before: String = ""
    @Published var after: String = ""
    /// Set when the panel is not proposing anything — see `loadTranscript`.
    @Published var note: String?
    @Published var status: String?
    /// Whether this is a dictation being corrected rather than a rewrite being
    /// proposed. The two want different things on screen — see the view.
    @Published var isTranscript: Bool = false
    /// Whether the text arrived short enough for a single-line field.
    ///
    /// Decided once, at load, and not recomputed as you type. A field that
    /// turned into a text area mid-sentence would take the caret with it.
    @Published var singleLine: Bool = false

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    func load(prompt: String, before: String, after: String) {
        self.prompt = prompt
        self.before = before
        self.after = after
        self.note = nil
        self.status = nil
        self.isTranscript = false
        self.singleLine = PreviewMetrics.singleLine(after)
    }

    /// The whole sentence, as it was heard, ready to be edited.
    ///
    /// The same panel as a transform preview because it is the same job: a
    /// block of text you are about to replace, editable before it goes in. The
    /// difference is who wrote the second copy — a prompt there, you here — so
    /// the two lines start out identical and the strikethrough only appears
    /// once you have changed something.
    ///
    /// Not the correction panel. That one splits what you give it into a row
    /// per word and each row is a rule that lands in config.yaml, which is the
    /// right shape for teaching a name and the wrong one for fixing a sentence:
    /// most of a misheard sentence is words you do not want to teach anything
    /// about.
    func loadTranscript(_ text: String) {
        self.prompt = "Dictation"
        self.before = text
        self.after = text
        self.note = "heard"
        self.status = "Fix anything I got wrong — this replaces what I typed"
        self.isTranscript = true
        self.singleLine = PreviewMetrics.singleLine(text)
    }

    /// Nothing to apply — the prompt returned what it was given.
    var isUnchanged: Bool {
        before.trimmingCharacters(in: .whitespacesAndNewlines)
            == after.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - View

struct PreviewView: View {
    @EnvironmentObject private var model: PreviewModel
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The transform preview keeps its header — you need to know which
            // prompt wrote the thing you are being asked to accept. Correcting
            // a dictation there is nothing to name: the sentence in the field
            // is your own, and "DICTATION · HEARD" over it was a label for a
            // thing that does not need labelling.
            if !model.isTranscript {
                header
            }

            // The instruction and the field are one group, and the group is
            // what sits in the middle. Spacers either side rather than a fixed
            // offset, so the same layout balances at any height the panel takes.
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                if model.isTranscript {
                    // An eyebrow, in the slot the other panels put one in, and
                    // quieter than the sentence under it. It was 19pt semibold
                    // with the bird beside it, which made the signage the
                    // loudest thing on a panel whose whole subject is the
                    // sentence you are checking. A label labels.
                    Text("Fix anything I got wrong".uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .kerning(0.9)
                        .foregroundStyle(.secondary)
                        // A word of it came up highlighted, which is what a
                        // selection looks like. Nothing draws a background
                        // there, so whatever put it there, saying the label is
                        // not selectable takes the possibility away.
                        .textSelection(.disabled)
                } else {
                    Text(model.before)
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                        .strikethrough(!model.isUnchanged, color: .secondary.opacity(0.4))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                field
            }

            Spacer(minLength: 0)

            PanelActions(
                status: model.isTranscript ? "" : (model.status ?? "Edit it here before replacing"),
                cancelTitle: "Discard",
                confirmTitle: "Replace",
                // One line commits on Return; an area needs the modifier,
                // because there Return is a newline.
                confirmKey: model.singleLine ? "↩" : "⌘↩",
                compact: model.isTranscript,
                onCancel: { model.onCancel?() },
                onConfirm: { model.onSubmit?() }
            )
        }
        .padding(Parrot.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .parrotSurface(
            RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
            solid: true
        )
        .background {
            PlumageBloom(
                shape: RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
                intensity: 1.7
            )
        }
        .padding(PreviewMetrics.bleed)
        .onExitCommand { model.onCancel?() }
    }

    /// One line gets a field; anything longer gets an area. Neither gets a box.
    ///
    /// The box was a fourth rectangle inside three others — glass, rim, glow —
    /// and it is what made a two-word correction look marooned in the middle of
    /// it. The sentence sits on the glass with a hairline under it, so the text
    /// is the surface rather than a thing parked on one.
    ///
    ///
    /// A text area holding a sentence that fits on a line is a box with an acre
    /// of empty under it and a caret you have to aim at. The panel grows
    /// sideways instead — see `PreviewMetrics.width(for:)` — so a sentence gets
    /// a line of its own for as long as the screen allows.
    ///
    /// 26pt in both. The old 13 was a caption, and this is the sentence about to
    /// go into your document: the one thing on screen worth reading carefully,
    /// and worth being able to put a caret in the middle of a word of without
    /// aiming.
    @ViewBuilder
    private var field: some View {
        if model.singleLine {
            // `EndCaretField` rather than `TextField`: SwiftUI's selects the
            // whole sentence when it takes focus, so the first key you press
            // throws away the thing you opened the panel to keep.
            EndCaretField(
                text: $model.after,
                fontSize: PreviewMetrics.fontSize,
                onSubmit: { model.onSubmit?() }
            )
            .frame(height: PreviewMetrics.fontSize + 6)
            .underlined()
        } else {
            TextEditor(text: $model.after)
                .font(.system(size: PreviewMetrics.fontSize))
                .scrollContentBackground(.hidden)
                .focused($editing)
                .frame(minHeight: 104)
                .underlined()
        }
    }

    private var header: some View {
        PanelHeader(
            title: model.prompt,
            note: model.note ?? (model.isUnchanged ? "nothing to change" : "proposed")
        )
    }
}
