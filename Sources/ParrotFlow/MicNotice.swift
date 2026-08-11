import AppKit
import SwiftUI

/// Says once, per microphone, that this microphone will cost you words.
///
/// A dialog rather than a line on the pill, and once rather than always, because
/// it is not a status — it is a thing to read, decide about, and not be told
/// again. On the pill it was either in the way of the offer or riding along
/// under the meter saying the same sentence into every dictation.
///
/// Collapsed to a sentence and a fix. The three reasons underneath are true and
/// worth having, and they are not what you need at the moment they appear —
/// what you need then is whether to go and change the microphone.
///
/// It never takes focus. It arrives just after a dictation, which is exactly
/// when you are typing again, and a dialog that stole the keyboard to give
/// advice would be a worse citizen than the microphone it is complaining about.
final class MicNotice {

    private var panel: NSPanel?
    private let model = MicNoticeModel()

    /// The microphone the last dictation was recorded on, whether or not
    /// anything was said about it.
    ///
    /// One slot rather than a list of the ones already mentioned, and that is
    /// the difference between "once ever" and what this is meant to be.
    /// Changing microphone forgets the one you left, so coming back to it says
    /// it again — that is a decision being revisited. A list cannot do that: it
    /// remembers every microphone the app has ever seen and never says anything
    /// twice.
    ///
    /// It only ever sees the microphone a dictation was on. Switching away and
    /// back with no dictation in between is not a change this can see, and
    /// nothing is said.
    private var lastMic: String?

    /// After a dictation, if it was recorded on Bluetooth and that microphone
    /// is not the one the last dictation used.
    ///
    /// The microphone is passed in rather than asked for here. It is frozen
    /// when the recording starts — see `micAtPress` in `AppDelegate` — because
    /// the default input can change while the decoder runs, and this is about
    /// the microphone that recorded these words. The transport comes from
    /// CoreAudio; see `Recorder.isBluetooth` for why it is the transport and
    /// not the name.
    func showIfNeeded(mic: String?, isBluetooth: Bool) {
        guard let mic else { return }
        guard lastMic != mic else { return }
        // Set for a wired microphone too. This is which microphone was last
        // decided about, not which one was last complained about, and a
        // dictation on the built-in mic is what makes going back to the
        // headset a new decision.
        lastMic = mic
        guard isBluetooth else { return }

        Log.write("mic: \(mic) is on Bluetooth; said so once")
        show(mic: mic)
    }

    /// Put it on screen for a named microphone, transport and `lastMic` aside.
    ///
    /// Split out so `--panels microphone` raises the surface the app raises,
    /// rather than a copy of it that can drift.
    func show(mic: String) {
        model.mic = mic
        // Collapsed again on every appearance: the disclosure is a decision
        // about the notice in front of you, not a preference to carry forward.
        model.expanded = false
        model.onClose = { [weak self] in self?.dismiss() }

        if panel == nil { build() }
        resize()
        reposition()
        // With the rise the other panels get, and without their key window:
        // this arrives on its own while you are typing into somebody else's
        // field. See `riseIntoView`.
        panel?.riseIntoView(makeKey: false)
    }

    /// Out at once, where the arrival is animated. The pill fades because it
    /// leaves on a timer; this leaves because you pressed the button on it, and
    /// a decision you made yourself should not have to play out. The correction
    /// and preview panels go the same way for the same reason.
    private func dismiss() {
        panel?.orderOut(nil)
    }

    private func build() {
        let hosting = NSHostingView(rootView: MicNoticeView().environmentObject(model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: MicNoticeMetrics.width,
                                height: MicNoticeMetrics.height(expanded: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.adoptParrotAppearance()
        self.panel = panel

        // Resize with the disclosure, so opening it does not clip the reasons.
        model.onResize = { [weak self] in self?.resize() }
    }

    private func resize() {
        guard let panel else { return }
        let height = MicNoticeMetrics.height(expanded: model.expanded)
        // The origin is kept, so the disclosure grows the panel upwards. It
        // sits on the bottom edge of the screen and has nowhere else to grow.
        let origin = panel.frame.origin
        panel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: MicNoticeMetrics.width, height: height),
            display: true, animate: panel.isVisible
        )
        panel.contentView?.frame = NSRect(
            x: 0, y: 0, width: MicNoticeMetrics.width, height: height
        )
    }

    /// Bottom right, out of the way of both the words and the pill.
    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - 24,
            y: frame.minY + 24
        ))
    }
}

enum MicNoticeMetrics {
    static let width: CGFloat = 380
    /// Two heights rather than a measured fit. The sentence is one device name
    /// long and the reasons are fixed text, so there is nothing here to
    /// measure that is not known when it is written — and both states are on
    /// `--panel-sheet`, where a name that outgrew the box would show.
    static func height(expanded: Bool) -> CGFloat { expanded ? 258 : 118 }
}

final class MicNoticeModel: ObservableObject {
    @Published var mic = "This microphone"
    @Published var expanded = false {
        didSet { onResize?() }
    }
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?
}

struct MicNoticeView: View {
    @EnvironmentObject private var model: MicNoticeModel

    private static let reasons = [
        ("Narrow band", "Bluetooth carries less of your voice than a wired mic does."),
        ("Aggressive gating", "Noise reduction takes quiet pauses and soft consonants for background noise, and mutes them."),
        ("Latency", "Wireless delay makes the recogniser misalign or drop words in fast speech."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Parrot.amber)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.mic) will cost you words")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Switch to the built-in mic for dictation.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if model.expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Self.reasons, id: \.0) { reason in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reason.0)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Parrot.amber.opacity(0.9))
                            Text(reason.1)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 21)
            }

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { model.expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(model.expanded ? 90 : 0))
                        Text(model.expanded ? "Less" : "Why")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button("Got it") { model.onClose?() }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(Color.white.opacity(0.12))
                    }
            }
        }
        .padding(Parrot.panelPadding)
        .frame(width: MicNoticeMetrics.width, alignment: .leading)
        .parrotSurface(
            RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
            solid: true
        )
    }
}
