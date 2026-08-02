import AppKit
import SwiftUI

/// State shared between the recorder and the floating pill.
final class OverlayModel: ObservableObject {
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    /// The icon of the app that was in front when the hotkey went down — the
    /// one an `app:` condition will be matched against and the one the text
    /// will land in. Nil when nothing was in front, or when the app has none.
    @Published var appIcon: NSImage?
}

/// A small non-interactive pill near the bottom of the screen, so you can tell
/// at a glance that the mic is hot without hunting for the menu bar icon.
final class RecordingOverlay {
    let model = OverlayModel()
    private var panel: NSPanel?

    func show() {
        if panel == nil { build() }
        // Before repositioning, not after: the pill is centred on the screen,
        // so a width set afterwards would leave it off-centre by half the icon.
        resize()
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The pill is two widths — with an app icon in it and without — and which
    /// one applies is only known when a recording starts. Done here rather than
    /// in the view because the panel is what has to change size; a SwiftUI
    /// frame inside a fixed panel would centre a narrow pill in a wide
    /// transparent box and take the shadow with it.
    private func resize() {
        guard let panel else { return }
        let size = NSSize(
            width: RecordingMetrics.width(hasIcon: model.appIcon != nil),
            height: RecordingMetrics.height
        )
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }

    private func build() {
        let hosting = NSHostingView(rootView: RecordingPill().environmentObject(model))
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: RecordingMetrics.width(hasIcon: model.appIcon != nil),
            height: RecordingMetrics.height
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
        panel.adoptParrotAppearance()
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

/// A red light, a live meter, and where the words are going.
///
/// Left to right that is a sentence: recording, hearing this, into this. The
/// destination sits at the end because it is the one part you read once and
/// stop watching — the meter is what moves, and it wants the middle. The
/// elapsed time was here once to prove the recorder was running, which is the
/// meter's job — it moves when you speak, which a clock does not. A clock next
/// to a hot mic only ever reads as pressure to hurry up.
///
/// The icon carries no mark of its own. It was tried with a scarlet ring around
/// it, which read as a red border painted on someone else's artwork and put a
/// second saturated shape next to the dot for no gain — the dot already says
/// the mic is hot, and saying it twice is what made the left half heavy.
///
/// **With no icon the pill is simply narrower**, back to the dot and the meter
/// it has always been. An empty slot held open is a hole you have to explain;
/// the two widths are set in `RecordingMetrics` and applied at `show()`, which
/// is the only moment either can change.
struct RecordingPill: View {
    @EnvironmentObject private var model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Parrot.scarlet)
                .frame(width: RecordingMetrics.dot, height: RecordingMetrics.dot)
                .shadow(color: Parrot.scarlet.opacity(0.7), radius: 4)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Meter(level: model.level)
                .frame(width: RecordingMetrics.meter, height: 16)
                .padding(.leading, RecordingMetrics.gap)

            if let icon = model.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: RecordingMetrics.icon, height: RecordingMetrics.icon)
                    .padding(.leading, RecordingMetrics.tuck)
            }
        }
        .padding(.horizontal, RecordingMetrics.padding)
        .frame(
            width: RecordingMetrics.width(hasIcon: model.appIcon != nil),
            height: RecordingMetrics.height
        )
        .parrotSurface(Capsule())
        // `initial: true` covers what `onAppear` did; the view stays alive
        // across recordings, so a Reduce Motion toggle mid-session needs the
        // same assignment again, not just on the first appearance.
        .onChange(of: reduceMotion, initial: true) { _, newValue in pulse = !newValue }
    }
}

enum RecordingMetrics {
    static let padding: CGFloat = 17
    static let gap: CGFloat = 11
    /// The gap on the meter's right, 2pt tighter than the one on its left.
    ///
    /// Both were 11 and did not look it. The dot is small, round and spills a
    /// little glow into its gap; the meter closes on its shortest, dimmest bar
    /// and the icon has a hard edge — so the eye measures from the last bar it
    /// can actually see to that edge, and reads that side as wider. Equal
    /// numbers, unequal gaps. These two are equal to look at.
    static let tuck: CGFloat = 9
    static let dot: CGFloat = 9
    static let icon: CGFloat = 24
    static let meter: CGFloat = 72
    static let height: CGFloat = 46

    /// 17 + 9 + 11 + 72 + 17, and the icon after the meter when there is one
    /// to show.
    static func width(hasIcon: Bool) -> CGFloat {
        let base = padding * 2 + dot + gap + meter
        return hasIcon ? base + icon + tuck : base
    }
}

/// The bars walk the plumage as they light up, left to right, so a loud sound
/// fills the pill with the same four colours that ring every other surface.
///
/// Against the wheel's direction: sky at the quiet end, scarlet at the loud
/// one. The last bars are the ones a shout reaches, and the colour arriving
/// there should be the one that means loud.
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
        Parrot.wheel[3 - min(3, index * 4 / bars)]
    }

    private func height(for index: Int) -> CGFloat {
        // Gentle arc so the meter reads as a waveform rather than a bar chart.
        let mid = CGFloat(bars - 1) / 2
        let distance = abs(CGFloat(index) - mid) / mid
        return 6 + (1 - distance) * 10
    }
}
