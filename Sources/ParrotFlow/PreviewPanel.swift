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

    func show(prompt: String, before: String, after: String) {
        model.load(prompt: prompt, before: before, after: after)
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
        let panel = PreviewKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: PreviewMetrics.width, height: 260),
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
        panel.onCancel = { [weak self] in self?.dismiss(cancelled: true) }
        self.panel = panel
    }

    /// Grows with the longer of the two texts, up to a cap.
    private func resize() {
        guard let panel else { return }
        let height = PreviewMetrics.height(
            forCharacters: max(model.before.count, model.after.count)
        )
        panel.setContentSize(NSSize(width: PreviewMetrics.width, height: height))
        panel.contentView?.frame = NSRect(
            x: 0, y: 0, width: PreviewMetrics.width, height: height
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

enum PreviewMetrics {
    static let width: CGFloat = 560
    private static let chrome: CGFloat = 146
    private static let minimumBody: CGFloat = 92
    private static let maximumBody: CGFloat = 320

    /// Roughly 74 characters to a line at this width and size.
    static func height(forCharacters count: Int) -> CGFloat {
        let lines = max(1, (count / 74) + 1)
        let body = min(maximumBody, max(minimumBody, CGFloat(lines) * 19 + 24))
        return chrome + body
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

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    func load(prompt: String, before: String, after: String) {
        self.prompt = prompt
        self.before = before
        self.after = after
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
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.before)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .strikethrough(!model.isUnchanged, color: .secondary.opacity(0.4))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextEditor(text: $model.after)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($editing)
                        .frame(minHeight: 44)
                        .parrotField(focused: editing)
                }
            }

            PanelActions(
                status: "Edit it here before replacing",
                cancelTitle: "Discard",
                confirmTitle: "Replace",
                onCancel: { model.onCancel?() },
                onConfirm: { model.onSubmit?() }
            )
        }
        .padding(Parrot.panelPadding)
        .frame(width: PreviewMetrics.width)
        .parrotSurface(RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous))
        .onExitCommand { model.onCancel?() }
    }

    private var header: some View {
        PanelHeader(
            title: model.prompt,
            note: model.isUnchanged ? "nothing to change" : "proposed"
        )
    }
}
