import AppKit
import SwiftUI

/// What a notice is telling you. Carried as a colour, because the notice is
/// read in half a second out of the corner of an eye, in the middle of typing
/// into something else — long enough for a colour, not for a sentence.
enum NoticeTone: Equatable {
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

/// What the pill is saying right now.
///
/// One enum rather than one panel each, because these are the same object at
/// different moments of the same dictation. The recording pill used to be an
/// `NSPanel` and the notice another, both borderless, both 46pt tall, both
/// centred on the same point 96pt off the bottom of the screen — so releasing
/// the hotkey destroyed one window and built another in its place, at more
/// than twice the width, with a different entrance. That reads as two unrelated
/// things happening, which is exactly what it was.
///
/// The level and the app icon are deliberately *not* in here. The meter is fed
/// about ten times a second and the icon is decided once at the press; putting
/// either in the state would make every meter frame a state change, and every
/// state change animates.
enum PillState: Equatable {
    /// The mic is hot. Width depends on whether there is an app icon to show.
    case recording
    /// Work of no predictable length — decoding, a prompt, a download.
    case working(String)
    /// A sentence, for a few seconds.
    case notice(String, NoticeTone)
    /// What you can do about what just happened, and the key that does it.
    case offer(String)
}

final class PillModel: ObservableObject {
    @Published var state: PillState = .recording
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    /// The icon of the app the text is going to land in — the one an `app:`
    /// condition will be matched against.
    ///
    /// Nil when nothing was in front, when the app has no icon, and when there
    /// was nothing in it to type into: the icon is a promise about where the
    /// words are going, and a window with no caret in it is not somewhere they
    /// can go. See `Destination`.
    @Published var appIcon: NSImage?
}

/// The one floating surface a dictation ever puts on screen.
///
/// It arrives once, changes shape as the dictation moves through its states,
/// and leaves once. Nothing in the middle is a new window: the panel keeps its
/// identity, animates its width, and crossfades what is written on it — so the
/// plumage rim never blinks, which is what made the old hand-off read as a
/// glitch on top of whatever you were reading.
final class PillHUD {

    let model = PillModel()

    private var panel: NSPanel?
    /// Armed by `hide()`, cancelled by the next `set()`. See `hide()`.
    private var pendingHide: DispatchWorkItem?
    /// Armed by a `set()` that carries a duration.
    private var pendingDismiss: DispatchWorkItem?
    private var isFading = false

    /// One number for the whole surface: the rise, the morph and the fade.
    ///
    /// The panel frame animates in AppKit and the words crossfade in SwiftUI,
    /// which are two animations that have to look like one. They are only ever
    /// going to agree if they read the same constant.
    static let motion: TimeInterval = 0.18

    // MARK: - The states

    func recording(icon: NSImage?) {
        model.elapsed = 0
        model.level = 0
        model.appIcon = icon
        set(.recording)
    }

    /// Stays up until something replaces it or `hide()` is called.
    ///
    /// A `duration` was tried here and lost: it is a bet on how long the work
    /// will take, and "Thinking…" dismissed itself while a cold Ollama was
    /// still loading the model — leaving the rest of a 10s wait looking like
    /// the app had gone back to doing nothing.
    func working(_ message: String) {
        set(.working(message))
    }

    /// A `duration` of nil leaves the message up until `hide()`.
    func notice(_ message: String, tone: NoticeTone = .plain, duration: TimeInterval? = 3.5) {
        set(.notice(message, tone), for: duration)
    }

    /// What you can do about the text that just landed, and for how long.
    func offer(_ label: String, for duration: TimeInterval) {
        set(.offer(label), for: duration)
    }

    // MARK: - Coming and going

    /// Put a state on screen, and take the surface away again after `duration`.
    ///
    /// The first state fades in. Every state after it morphs, because by then
    /// there is already a pill there and the user is looking at it.
    func set(_ state: PillState, for duration: TimeInterval? = nil) {
        pendingHide?.cancel(); pendingHide = nil
        pendingDismiss?.cancel(); pendingDismiss = nil

        if panel == nil { build() }
        guard let panel else { return }

        // A fade that has not finished is a panel that is still on screen. Put
        // it back to full strength rather than morphing something half gone.
        if isFading {
            isFading = false
            panel.alphaValue = 1
        }

        // The words change with the frame, not after it: SwiftUI is told inside
        // the same turn that starts the AppKit animation, and both read
        // `PillHUD.motion`.
        withAnimation(.easeInOut(duration: Self.motion)) {
            model.state = state
        }

        let size = NSSize(
            width: PillMetrics.width(for: state, hasIcon: model.appIcon != nil),
            height: PillMetrics.height
        )

        if panel.isVisible {
            morph(to: size)
        } else {
            panel.setContentSize(size)
            panel.setFrameOrigin(anchor(width: size.width))
            fadeIn(panel)
        }

        guard let duration else { return }
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Take the pill away — unless something is about to put it back.
    ///
    /// Deferred by one pass of the run loop on purpose. Half the app's
    /// transitions are written as a hide followed by a show a few lines later,
    /// in the same turn: the recording ends and transcription starts, Escape
    /// stops a run and says so, a prompt finishes and a notice replaces it.
    /// Faded immediately, every one of those would blink out and back in.
    /// Deferred, the `set()` that follows cancels this and the pill simply
    /// changes shape — so those seams became morphs without a single call site
    /// having to know about it.
    func hide() {
        pendingDismiss?.cancel(); pendingDismiss = nil
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        pendingHide = work
        DispatchQueue.main.async(execute: work)
    }

    /// In without moving.
    ///
    /// The other floating surfaces rise 8pt as they appear — `riseIntoView`,
    /// which the correction and preview panels still use. This one must not.
    /// It is on screen for the whole of a dictation and changes state three or
    /// four times inside it, so it is the one surface whose position you learn
    /// and then read without looking at. Anything that moves it vertically is a
    /// thing to re-find.
    ///
    /// It was tried with the rise and the rise is what put it 8pt low: the
    /// entrance animation did not run, so the pill sat at its start position
    /// through the whole recording and only climbed to where it belonged when
    /// the next state morphed it there. Nothing to animate is nothing to get
    /// wrong.
    private func fadeIn(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Out the same way: alpha only.
    ///
    /// Every dismissal in the app used to be a bare `orderOut` — the surface
    /// was simply not there on the next frame. An arrival worth animating is an
    /// exit worth animating: an instant cut is read as something having gone
    /// wrong, which for the failure notices is the one wrong thing to say.
    private func fadeOut() {
        pendingHide = nil
        pendingDismiss = nil
        guard let panel, panel.isVisible, !isFading else { return }

        isFading = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.isFading else { return }
            self.isFading = false
            panel.orderOut(nil)
            // Back to full strength while off screen, or the next appearance
            // starts from a panel that is already invisible and stays that way.
            panel.alphaValue = 1
        }
    }

    /// Grow or shrink in place, from the middle.
    ///
    /// The origin moves in the same animation group as the size. The pill is
    /// centred on the screen, so a width applied without a matching origin
    /// would leave it growing out of its left edge — which is the one direction
    /// it must not grow, because the dot on that edge is the thing the eye is
    /// resting on.
    private func morph(to size: NSSize) {
        guard let panel else { return }
        let frame = NSRect(origin: anchor(width: size.width), size: size)
        guard frame != panel.frame else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func build() {
        let hosting = NSHostingView(rootView: PillView().environmentObject(model))
        hosting.frame = NSRect(x: 0, y: 0, width: PillMetrics.recording(hasIcon: false),
                               height: PillMetrics.height)
        // The panel is what resizes; the view follows it. Done this way round
        // because a SwiftUI frame inside a fixed panel centres a narrow pill in
        // a wide transparent box and takes the shadow with it.
        hosting.autoresizingMask = [.width, .height]
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

    /// Where a pill of this width sits: centred, 96pt off the bottom, on the
    /// screen the pointer is on — which is the screen you are typing into.
    ///
    /// Recomputed at every state rather than once at the first show, so a pill
    /// that grows stays centred and one that arrives after you have moved to
    /// the other monitor arrives on that one.
    private func anchor(width: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return panel?.frame.origin ?? .zero }
        return NSPoint(x: visible.midX - width / 2, y: visible.minY + 96)
    }
}

// MARK: - Metrics

enum PillMetrics {
    static let height: CGFloat = 46

    /// Wide enough for the widest blur's tail to reach zero before the window
    /// ends.
    ///
    /// At 24 it did not: the outer layer was cut off while still bright, which
    /// reads as a second ring drawn on purpose. A Gaussian is visually gone by
    /// about twice its radius, and the widest here is 24.
    ///
    /// Kept as tight as that allows rather than as wide as possible. The window
    /// is transparent but not invisible — a faint rectangle can still be made
    /// out where its bounds are, so the less of it there is beyond the glow, the
    /// less there is to see.
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

    static func width(for state: PillState, hasIcon: Bool) -> CGFloat {
        switch state {
        case .recording: return recording(hasIcon: hasIcon)
        case .working(let message): return text(message)
        case .notice(let message, _): return text(message)
        case .offer(let label): return offer(label)
        }
    }

    /// 17 + 9 + 11 + 72 + 17, and the icon after the meter when there is one
    /// to show.
    static func recording(hasIcon: Bool) -> CGFloat {
        let base = padding * 2 + dot + gap + meter
        return hasIcon ? base + icon + tuck : base
    }

    /// Wide enough for the message, the dot in front of it and the padding —
    /// the text is one line and truncating it would lose the half that says
    /// what to do about it.
    static func text(_ message: String) -> CGFloat {
        min(600, max(300, CGFloat(message.count) * 8 + 86))
    }

    /// The offer is a short question wrapped around a keycap, and it has no
    /// minimum.
    ///
    /// Unlike a message, which is a sentence you have to be able to read to the
    /// end, this is a shape you learn after seeing it twice. Held to the 300pt
    /// floor it would be a mostly empty pill, and an offer that looks like a
    /// notice reads as something having gone wrong.
    ///
    /// "Wrong?" and "to fix it" either side, with 8pt between the three.
    ///
    /// Generous rather than tight. The three parts are laid out by SwiftUI and
    /// measured here, and the two numbers only ever agree approximately — a
    /// capsule a few points too wide has a little air at the end, one a few
    /// points too narrow truncates the sentence it exists to ask.
    static func offer(_ label: String) -> CGFloat {
        padding * 2 + 58 + 8 + keycap(label) + 8 + 56
    }

    static func keycap(_ label: String) -> CGFloat {
        max(30, CGFloat(label.count) * 7.5 + 16)
    }
}

// MARK: - View

/// A red light, a live meter, and where the words are going — and then whatever
/// the same pill has to say next.
///
/// Left to right the recording state is a sentence: recording, hearing this,
/// into this. The destination sits at the end because it is the one part you
/// read once and stop watching — the meter is what moves, and it wants the
/// middle. The elapsed time was here once to prove the recorder was running,
/// which is the meter's job — it moves when you speak, which a clock does not.
/// A clock next to a hot mic only ever reads as pressure to hurry up.
///
/// The icon carries no mark of its own. It was tried with a scarlet ring around
/// it, which read as a red border painted on someone else's artwork and put a
/// second saturated shape next to the dot for no gain — the dot already says
/// the mic is hot, and saying it twice is what made the left half heavy.
///
/// **With no icon the pill is simply narrower**, back to the dot and the meter
/// it has always been. An empty slot held open is a hole you have to explain.
///
/// The narrow pill is also the warning. The icon appears when there is a field
/// with keyboard focus to write into — not merely when an app is in front — so
/// its absence says the words have nowhere to go and will be copied instead.
/// That is a thing worth knowing while you are still talking, and it is told by
/// the shape of the pill rather than by a second word on it: the pill is read in
/// peripheral vision, and something being missing is the one difference that
/// registers there.
struct PillView: View {
    @EnvironmentObject private var model: PillModel

    var body: some View {
        ZStack {
            switch model.state {
            case .recording:
                RecordingContent(level: model.level, icon: model.appIcon)
                    .transition(.opacity)
            case .working(let message):
                MessageContent(message: message, tone: .thinking)
                    .transition(.opacity)
            case .notice(let message, let tone):
                MessageContent(message: message, tone: tone)
                    .transition(.opacity)
            case .offer(let label):
                OfferContent(label: label)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .parrotSurface(Capsule(), alive: isWorking)
        // Bound to the state alone. The meter is fed about ten times a second
        // and must not drag a crossfade along behind it.
        .animation(.easeInOut(duration: PillHUD.motion), value: model.state)
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }
}

private struct RecordingContent: View {
    let level: Float
    let icon: NSImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Parrot.scarlet)
                .frame(width: PillMetrics.dot, height: PillMetrics.dot)
                .shadow(color: Parrot.scarlet.opacity(0.7), radius: 4)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Meter(level: level)
                .frame(width: PillMetrics.meter, height: 16)
                .padding(.leading, PillMetrics.gap)

            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: PillMetrics.icon, height: PillMetrics.icon)
                    .padding(.leading, PillMetrics.tuck)
            }
        }
        .padding(.horizontal, PillMetrics.padding)
        // `initial: true` covers what `onAppear` did; the view stays alive
        // across recordings, so a Reduce Motion toggle mid-session needs the
        // same assignment again, not just on the first appearance.
        .onChange(of: reduceMotion, initial: true) { _, newValue in pulse = !newValue }
    }
}

private struct MessageContent: View {
    let message: String
    let tone: NoticeTone

    var body: some View {
        HStack(spacing: PillMetrics.gap) {
            ToneDot(tone: tone)

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PillMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The key you can press, and what it does.
///
/// A keycap rather than a dot, because this is the one state that is not news
/// about something that already happened — it is a thing you can still do, and
/// the difference has to be visible before the words are read. The key is drawn
/// from the binding that is actually registered, so a config that moved the
/// hotkey moves what this advertises. Offering a key that does nothing is worse
/// than offering nothing.
private struct OfferContent: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            // The question first. "Correct" alone named the action without
            // saying what it was for, which reads as an instruction to correct
            // something rather than an offer to fix what just landed — and the
            // answer to it is usually no, so it has to be askable at a glance.
            Text("Wrong?")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)

            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                // A key's name is one line whatever it is. Without this the
                // capsule's width wins the argument and "Right ⌘" wraps to two.
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                        }
                }

            Text("to fix it")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PillMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole of the notice's colour, in nine points.
///
/// It carries the tone alone, now that the surface behind it stays dark — so it
/// is lit rather than filled: the glow is what makes green and amber tell each
/// other apart at the edge of vision.
///
/// While thinking it walks the plumage rather than pulsing one colour: pulsing
/// is what the recording state's red dot does, and the two are now the same
/// surface seconds apart, so they must not be mistakable for each other.
struct ToneDot: View {
    let tone: NoticeTone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    private let clock = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color, radius: 4)
            .shadow(color: color.opacity(0.6), radius: 9)
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
