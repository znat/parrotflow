import AppKit
import SwiftUI

/// What a notice is telling you. Carried as a colour, because the notice is
/// read in half a second out of the corner of an eye, in the middle of typing
/// into something else — long enough for a colour, not for a sentence.
enum NoticeTone {
    /// Something happened, and it worked.
    case done
    /// Nothing broke, but nothing happened either, and you may want to know why.
    case caution
    /// It failed.
    case failure
    /// Working, for as long as it takes.
    case thinking
    /// Plain news.
    case plain

    var color: Color {
        switch self {
        case .done: return Parrot.leaf
        case .caution: return Parrot.amber
        case .failure: return Parrot.scarlet
        case .thinking, .plain: return Parrot.sky
        }
    }
}

/// A transient message near where the recording pill appears.
///
/// Exists because `flash()` used to write only to a menu bar item, which
/// nobody has open — so "didn't understand that", "Accessibility not granted"
/// and "selection gone" all looked identical to the app doing nothing at all.
/// A menu bar app has no other way to say something went wrong short of an
/// alert, which is far too heavy for this.
///
/// Same material, same rim and same rounded type as the dialogs it appears
/// alongside: it is the one-line version of the same voice.
final class NoticeHUD {

    private var panel: NSPanel?
    private let model = NoticeModel()
    private var dismissWorkItem: DispatchWorkItem?

    /// A `duration` of nil leaves the message up until `hide()`.
    ///
    /// Needed because the fixed 3.5s was a bet on how long the work would take,
    /// and it lost: "Thinking…" dismissed itself while a cold Ollama was still
    /// loading the model, so the rest of a 10s wait looked like the app had
    /// gone back to doing nothing. Anything unbounded — a model call, a
    /// download — has to hold the HUD until it finishes.
    func show(_ message: String, tone: NoticeTone = .plain, duration: TimeInterval? = 3.5) {
        model.message = message
        model.tone = tone

        if panel == nil { build() }
        resize()
        reposition()
        panel?.riseIntoView(makeKey: false)

        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let duration else { return }

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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: NoticeMetrics.height),
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
        let size = NSSize(width: NoticeMetrics.width(for: model.message), height: NoticeMetrics.height)
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

enum NoticeMetrics {
    static let height: CGFloat = 46

    /// Wide enough for the message, the dot in front of it and the padding —
    /// the text is one line and truncating it would lose the half that says
    /// what to do about it.
    static func width(for message: String) -> CGFloat {
        min(600, max(300, CGFloat(message.count) * 8 + 86))
    }
}

final class NoticeModel: ObservableObject {
    @Published var message: String = ""
    @Published var tone: NoticeTone = .plain
}

struct NoticeView: View {
    @EnvironmentObject private var model: NoticeModel

    var body: some View {
        HStack(spacing: 11) {
            ToneDot(tone: model.tone)

            Text(model.message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .parrotSurface(
            Capsule(),
            alive: model.tone == .thinking,
            tint: model.tone == .thinking ? nil : model.tone.color
        )
    }
}

/// The whole of the notice's colour, in seven points.
///
/// While thinking it walks the plumage rather than pulsing one colour: pulsing
/// is what the recording pill's red dot does, and the two appear in the same
/// place seconds apart, so they must not be mistakable for each other.
struct ToneDot: View {
    let tone: NoticeTone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    private let clock = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.8), radius: 5)
            .animation(.easeInOut(duration: 0.5), value: step)
            .onReceive(clock) { _ in
                guard tone == .thinking, !reduceMotion else { return }
                step += 1
            }
    }

    private var color: Color {
        guard tone == .thinking else { return tone.color }
        return Parrot.wheel[step % 4]
    }
}
