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
        hosting.frame = NSRect(
            x: 0, y: 0, width: RecordingMetrics.width, height: RecordingMetrics.height
        )

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

/// A red dot and a live meter, and nothing else.
///
/// The elapsed time was here to prove the recorder was running, which is the
/// meter's job — it moves when you speak, which a clock does not. A clock next
/// to a hot mic only ever reads as pressure to hurry up.
struct RecordingPill: View {
    @EnvironmentObject private var model: OverlayModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Parrot.scarlet)
                .frame(width: 9, height: 9)
                .shadow(color: Parrot.scarlet.opacity(0.7), radius: 4)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Meter(level: model.level)
                .frame(width: 72, height: 16)
        }
        .padding(.horizontal, 17)
        .frame(width: RecordingMetrics.width, height: RecordingMetrics.height)
        .parrotSurface(Capsule())
        .onAppear { pulse = true }
    }
}

enum RecordingMetrics {
    static let width: CGFloat = 128
    static let height: CGFloat = 46
}

/// The bars walk the plumage as they light up, left to right, so a loud sound
/// fills the pill with the same four colours that ring every other surface.
struct Meter: View {
    let level: Float
    private let bars = 12

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { index in
                let threshold = Float(index + 1) / Float(bars)
                let active = level >= threshold * 0.85
                Capsule()
                    .fill(active ? feather(index) : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: active ? height(for: index) : 4)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func feather(_ index: Int) -> Color {
        Parrot.wheel[min(3, index * 4 / bars)]
    }

    private func height(for index: Int) -> CGFloat {
        // Gentle arc so the meter reads as a waveform rather than a bar chart.
        let mid = CGFloat(bars - 1) / 2
        let distance = abs(CGFloat(index) - mid) / mid
        return 6 + (1 - distance) * 10
    }
}
