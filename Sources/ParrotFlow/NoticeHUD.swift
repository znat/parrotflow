import AppKit
import SwiftUI

/// A transient message near where the recording pill appears.
///
/// Exists because `flash()` used to write only to a menu bar item, which
/// nobody has open — so "didn't understand that", "Accessibility not granted"
/// and "selection gone" all looked identical to the app doing nothing at all.
/// A menu bar app has no other way to say something went wrong short of an
/// alert, which is far too heavy for this.
final class NoticeHUD {

    private var panel: NSPanel?
    private let model = NoticeModel()
    private var dismissWorkItem: DispatchWorkItem?

    func show(_ message: String, duration: TimeInterval = 3.5) {
        model.message = message

        if panel == nil { build() }
        resize()
        reposition()
        panel?.orderFrontRegardless()

        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        dismissWorkItem?.cancel()
        panel?.orderOut(nil)
    }

    private func build() {
        let hosting = NSHostingView(rootView: NoticeView().environmentObject(model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel = panel
    }

    private func resize() {
        guard let panel, let content = panel.contentView else { return }
        let width = min(560, max(280, model.message.count * 8 + 60))
        let size = NSSize(width: CGFloat(width), height: 44)
        panel.setContentSize(size)
        content.frame = NSRect(origin: .zero, size: size)
    }

    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 96
        ))
    }
}

final class NoticeModel: ObservableObject {
    @Published var message: String = ""
}

private struct NoticeView: View {
    @EnvironmentObject private var model: NoticeModel

    var body: some View {
        Text(model.message)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}
