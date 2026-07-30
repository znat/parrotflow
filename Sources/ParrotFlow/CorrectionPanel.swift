import AppKit
import SwiftUI

/// The teach-a-word panel: shows what ParrotFlow wrote, and takes what it
/// should have written.
///
/// Visually a sibling of the recording pill — same translucent material, same
/// hairline border, same spot on screen — so the two read as one object in two
/// states: listening, and being corrected.
///
/// The words themselves are set in monospace. They are literal strings being
/// mapped to other literal strings, not prose, and the rule that comes out of
/// this panel is the line that lands in config.yaml.
final class CorrectionPanel {

    private var panel: KeyPanel?
    private var model = CorrectionModel()

    /// Called with (heard, corrected) when the rule is confirmed.
    var onSave: ((String, String) -> Void)?
    var onCancel: (() -> Void)?

    func show(heard: String) {
        model.heard = heard
        model.corrected = heard
        model.onSubmit = { [weak self] in self?.commit() }
        model.onCancel = { [weak self] in self?.dismiss(cancelled: true) }

        if panel == nil { build() }
        reposition()

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func commit() {
        let heard = model.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = model.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != heard else {
            dismiss(cancelled: true)
            return
        }
        dismiss(cancelled: false)
        onSave?(heard, corrected)
    }

    private func dismiss(cancelled: Bool) {
        panel?.orderOut(nil)
        if cancelled { onCancel?() }
    }

    private func build() {
        let hosting = NSHostingView(rootView: CorrectionView().environmentObject(model))
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 132)

        let panel = KeyPanel(
            contentRect: hosting.frame,
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
        self.panel = panel
    }

    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 160
        ))
    }
}

/// Borderless panels refuse key status by default, which would leave the text
/// field unable to take a single keystroke.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Model

final class CorrectionModel: ObservableObject {
    @Published var heard: String = ""
    @Published var corrected: String = ""
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
}

// MARK: - View

private struct CorrectionView: View {
    @EnvironmentObject private var model: CorrectionModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                field(label: "Heard as") {
                    Text(model.heard)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                    .padding(.top, 18)

                field(label: "Should be") {
                    TextField("", text: $model.corrected)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .focused($fieldFocused)
                        .onSubmit { model.onSubmit?() }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.accentColor.opacity(fieldFocused ? 0.8 : 0), lineWidth: 1.5)
                        )
                }
            }

            HStack(spacing: 14) {
                hint("return", "Save rule")
                hint("esc", "Cancel")
                Spacer()
                Text("Applies here and every time after")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(width: 460, height: 132)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .onAppear { fieldFocused = true }
        .onExitCommand { model.onCancel?() }
    }

    private func field<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
            Text(meaning)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
