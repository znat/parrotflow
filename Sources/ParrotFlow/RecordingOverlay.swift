import AppKit
import SwiftUI

/// State shared between the recorder and the floating pill.
final class OverlayModel: ObservableObject {
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
}

/// A small non-interactive pill near the bottom of the screen, so you can tell
/// at a glance that the mic is hot without hunting for the menu bar icon.
final class RecordingOverlay {
    let model = OverlayModel()
    private var panel: NSPanel?

    func show() {
        if panel == nil { build() }
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func build() {
        let hosting = NSHostingView(rootView: RecordingPill().environmentObject(model))
        hosting.frame = NSRect(x: 0, y: 0, width: 168, height: 44)

        let panel = NSPanel(
            contentRect: hosting.frame,
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

    private func reposition() {
        guard let panel else { return }
        // Follow the screen the pointer is on — matches where the user is typing.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96
        ))
    }
}

// MARK: - View

private struct RecordingPill: View {
    @EnvironmentObject private var model: OverlayModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Text(timeString)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Meter(level: model.level)
                .frame(width: 58, height: 16)
        }
        .padding(.horizontal, 16)
        .frame(width: 168, height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .onAppear { pulse = true }
    }

    private var timeString: String {
        let total = Int(model.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Meter: View {
    let level: Float
    private let bars = 9

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { index in
                let threshold = Float(index + 1) / Float(bars)
                let active = level >= threshold * 0.85
                Capsule()
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: active ? height(for: index) : 4)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func height(for index: Int) -> CGFloat {
        // Gentle arc so the meter reads as a waveform rather than a bar chart.
        let mid = CGFloat(bars - 1) / 2
        let distance = abs(CGFloat(index) - mid) / mid
        return 6 + (1 - distance) * 10
    }
}
