import AppKit
import SwiftUI

/// Teach me the words I got wrong.
///
/// A table: what was heard, what it should be, what kind of thing it names. The
/// rows are proposed by the spell check rather than typed from nothing — see
/// `VocabularySuggest` for what it finds and what it cannot.
///
/// Visually a sibling of the pill: near-black at 95%, the same plumage rim.
final class CorrectionPanel {

    private var panel: KeyPanel?
    private let model = CorrectionModel()

    /// (rules to save, the full corrected text to put back).
    var onSave: (([TaughtRule], String) -> Void)?
    var onCancel: (() -> Void)?

    func show(selection: String, language: String? = nil) {
        model.load(sentence: selection, language: language)
        present()
    }

    /// Opens with the rules already filled in — the model proposed them, you
    /// confirm them.
    func show(rules: [(heard: String, corrected: String)], over sentence: String = "") {
        model.load(rules: rules, over: sentence)
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

        // Focus again on the next turn of the runloop, and not before. Two
        // things have to be true before a field can show a caret, and neither
        // is true on this turn: there has to be a window to be first responder
        // in, and that window has to be key — a field made first responder in a
        // window that is not key draws no insertion point. `NSApp.activate`
        // only lands on the next turn, so the key status is asked for again
        // there rather than trusted here.
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel else { return }
            if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        }
    }

    private func commit() {
        // Twice is possible: Return reaches the confirm button and the field's
        // own newline handler. Once the panel is down there is nothing left to
        // save.
        guard panel?.isVisible == true else { return }
        let rules = model.rules()
        let corrected = model.correctedText()
        dismiss(cancelled: false)
        onSave?(rules, corrected)
    }

    /// Escape reaches here twice — once through the button that advertises it,
    /// once through the panel's own `cancelOperation` for when nothing inside
    /// holds focus. Whichever arrives first closes the panel; the other finds
    /// it already gone.
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
        self.panel = panel
    }

    /// Grows with the number of rows, up to a scrolling cap.
    private func resize() {
        guard let panel else { return }
        let height = CorrectionMetrics.height(forRows: model.rows.count)
        panel.setContentSize(NSSize(width: CorrectionMetrics.width, height: height))
        panel.contentView?.frame = NSRect(
            x: 0, y: 0, width: CorrectionMetrics.width, height: height
        )
    }

    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }
}

enum CorrectionMetrics {
    static let heardWidth: CGFloat = 165
    static let arrowWidth: CGFloat = 12
    static let correctedWidth: CGFloat = 185
    static let kindWidth: CGFloat = 84
    /// The three columns, the arrow, the ✕, and the gaps between them.
    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 40
    static let maxRows = 7
    /// Title, column labels, the add-a-word row, and the buttons. Measured
    /// against the drawn panel, not derived from the fonts.
    private static let chrome: CGFloat = 162

    /// The scrolling area. Exactly the rows it shows, so a row is never drawn
    /// half over the edge of it.
    static func rowsHeight(_ rows: Int) -> CGFloat {
        rowHeight * CGFloat(max(1, min(rows, maxRows)))
    }

    static func height(forRows rows: Int) -> CGFloat {
        chrome + rowsHeight(rows)
    }
}

/// Borderless panels refuse key status, which would leave every field unable
/// to take a keystroke.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// SwiftUI's `onExitCommand` only fires when something inside holds focus.
    /// Handling it on the panel means Escape always closes, even if the view
    /// somehow renders with nothing focusable.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
